# -*- coding: utf-8 -*-
"""Markdown -> .docx (WordprocessingML, written directly; no external deps)."""
import re, sys, io, zipfile
from xml.sax.saxutils import escape

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'

def runs(text, mono=False, force_bold=False):
    """Split inline markdown (**bold**, `code`) into <w:r> runs."""
    out = []
    for part in re.split(r'(\*\*[^*]+\*\*|`[^`]+`)', text):
        if not part:
            continue
        bold, code, t = force_bold, mono, part
        if part.startswith('**') and part.endswith('**') and len(part) > 4:
            bold, t = True, part[2:-2]
        elif part.startswith('`') and part.endswith('`') and len(part) > 2:
            code, t = True, part[1:-1]
        t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'\1', t)
        rpr = ''
        if bold:
            rpr += '<w:b/>'
        if code:
            rpr += ('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="MS Gothic"/>'
                    '<w:sz w:val="18"/><w:szCs w:val="18"/>')
        rpr = f'<w:rPr>{rpr}</w:rPr>' if rpr else ''
        out.append(f'<w:r>{rpr}<w:t xml:space="preserve">{escape(t)}</w:t></w:r>')
    return ''.join(out) or '<w:r><w:t/></w:r>'

def para(text, style=None, mono=False, shade=None, indent=None, bold=False):
    ppr = ''
    if style:
        ppr += f'<w:pStyle w:val="{style}"/>'
    if indent:
        ppr += f'<w:ind w:left="{indent}"/>'
    if shade:
        ppr += f'<w:shd w:val="clear" w:color="auto" w:fill="{shade}"/>'
    if mono:
        ppr += '<w:spacing w:after="0"/>'
    ppr = f'<w:pPr>{ppr}</w:pPr>' if ppr else ''
    return f'<w:p>{ppr}{runs(text, mono=mono, force_bold=bold)}</w:p>'

def table(hdr, rows):
    ncol = max([len(hdr)] + [len(r) for r in rows]) or 1
    width = 9360 // ncol
    borders = ('<w:tblBorders>' + ''.join(
        f'<w:{s} w:val="single" w:sz="4" w:space="0" w:color="808080"/>'
        for s in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV')) + '</w:tblBorders>')
    xml = ('<w:tbl><w:tblPr><w:tblW w:w="9360" w:type="dxa"/>' + borders +
           '<w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid>' +
           ''.join(f'<w:gridCol w:w="{width}"/>' for _ in range(ncol)) + '</w:tblGrid>')
    def row(cells, header=False):
        s = '<w:tr>'
        if header:
            s += '<w:trPr><w:tblHeader/></w:trPr>'
        for i in range(ncol):
            c = cells[i] if i < len(cells) else ''
            shd = '<w:shd w:val="clear" w:color="auto" w:fill="DCE6F1"/>' if header else ''
            s += (f'<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/>{shd}</w:tcPr>'
                  f'<w:p><w:pPr><w:spacing w:after="0"/></w:pPr>{runs(c, force_bold=header)}</w:p></w:tc>')
        return s + '</w:tr>'
    xml += row(hdr, header=True)
    for r in rows:
        xml += row(r)
    return xml + '</w:tbl>' + '<w:p><w:pPr><w:spacing w:after="0"/></w:pPr></w:p>'

def convert(md):
    body, i = [], 0
    lines = md.split('\n')
    while i < len(lines):
        ln = lines[i]
        if ln.startswith('```'):
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                body.append(para(lines[i] or ' ', mono=True, shade='F2F2F2')); i += 1
            i += 1
            body.append('<w:p/>'); continue
        m = re.match(r'^(#{1,6})\s+(.*)$', ln)
        if m:
            body.append(para(m.group(2), style='Heading%d' % min(len(m.group(1)), 3)))
            i += 1; continue
        if re.match(r'^\s*\|.*\|\s*$', ln) and i + 1 < len(lines) and re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i+1]):
            cells = lambda s: [c.strip() for c in s.strip().strip('|').split('|')]
            hdr = cells(ln); i += 2; rows = []
            while i < len(lines) and re.match(r'^\s*\|.*\|\s*$', lines[i]):
                rows.append(cells(lines[i])); i += 1
            body.append(table(hdr, rows)); continue
        m = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)$', ln)
        if m:
            while i < len(lines):
                m2 = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)$', lines[i])
                if not m2:
                    break
                depth = len(m2.group(1)) // 2
                mark = '・' if m2.group(2) in ('-', '*') else m2.group(2) + ' '
                body.append(para(mark + m2.group(3), indent=360 + depth * 360))
                i += 1
            continue
        if ln.startswith('>'):
            buf = []
            while i < len(lines) and lines[i].startswith('>'):
                buf.append(lines[i].lstrip('>').strip()); i += 1
            for b in buf:
                body.append(para(b or ' ', indent=360, shade='F7F7F7'))
            continue
        if re.match(r'^---+\s*$', ln):
            body.append('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" '
                        'w:color="AAAAAA"/></w:pBdr></w:pPr></w:p>'); i += 1; continue
        if ln.strip() == '':
            i += 1; continue
        buf = []
        while i < len(lines) and lines[i].strip() and not re.match(
                r'^(#{1,6}\s|```|\s*\||\s*[-*]\s|\s*\d+\.\s|>|---+\s*$)', lines[i]):
            buf.append(lines[i]); i += 1
        body.append(para(' '.join(buf)))
    return ''.join(body)

STYLES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="%s">
<w:docDefaults><w:rPrDefault><w:rPr>
<w:rFonts w:ascii="Yu Gothic" w:hAnsi="Yu Gothic" w:eastAsia="Yu Gothic" w:cs="Yu Gothic"/>
<w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:rPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>
<w:pPr><w:spacing w:after="120"/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
<w:pPr><w:outlineLvl w:val="0"/><w:spacing w:before="360" w:after="180"/></w:pPr>
<w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="1F3864"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>
<w:pPr><w:outlineLvl w:val="1"/><w:spacing w:before="280" w:after="140"/>
<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="2" w:color="8EAADB"/></w:pBdr></w:pPr>
<w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="1F3864"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/>
<w:pPr><w:outlineLvl w:val="2"/><w:spacing w:before="220" w:after="110"/></w:pPr>
<w:rPr><w:b/><w:sz w:val="24"/><w:color w:val="2E5496"/></w:rPr></w:style>
</w:styles>''' % W

CONTENT_TYPES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>'''

RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''

DOC_RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>'''

def write_docx(md_path, out_path):
    body = convert(io.open(md_path, encoding='utf-8').read())
    doc = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
           f'<w:document xmlns:w="{W}"><w:body>{body}'
           '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
           '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
           'w:header="851" w:footer="992" w:gutter="0"/></w:sectPr></w:body></w:document>')
    with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', CONTENT_TYPES)
        z.writestr('_rels/.rels', RELS)
        z.writestr('word/_rels/document.xml.rels', DOC_RELS)
        z.writestr('word/styles.xml', STYLES)
        z.writestr('word/document.xml', doc)
    print('wrote', out_path)

write_docx(sys.argv[1], sys.argv[2])
