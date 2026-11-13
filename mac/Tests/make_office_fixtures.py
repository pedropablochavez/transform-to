"""Writes sample .pptx/.xlsx files for the Mac smoke test (mac/Tests/TransformToTests).

Usage: python make_office_fixtures.py <output folder>   (needs: pip install python-pptx openpyxl)
"""
import datetime
import os
import struct
import sys
import zlib

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.dml.color import RGBColor
from pptx.enum.chart import XL_CHART_TYPE
from pptx.enum.shapes import MSO_CONNECTOR, MSO_SHAPE
from pptx.util import Emu, Inches, Pt


def gradient_png(width=320, height=200):
    rows = b"".join(
        b"\x00" + bytes(v for x in range(width) for v in (x * 255 // width, y * 255 // height, 160))
        for y in range(height)
    )

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def presentation(path, image):
    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)

    slide = prs.slides.add_slide(prs.slide_layouts[0])
    slide.shapes.title.text = "Transform To"
    slide.placeholders[1].text = "PowerPoint to PDF on a Mac, with nothing installed"

    slide = prs.slides.add_slide(prs.slide_layouts[1])
    slide.shapes.title.text = "Bullets and levels"
    body = slide.placeholders[1].text_frame
    body.text = "First level bullet"
    for text, level in [("Second level", 1), ("Third level, a bit longer so that it has to wrap onto a second line "
                                              "inside the placeholder", 2), ("Back to the first level", 0)]:
        p = body.add_paragraph()
        p.text, p.level = text, level
    p = body.add_paragraph()
    run = p.add_run()
    run.text = "Bold red "
    run.font.bold, run.font.color.rgb = True, RGBColor(0xC0, 0x00, 0x00)
    run = p.add_run()
    run.text = "italic underlined"
    run.font.italic, run.font.underline = True, True

    slide = prs.slides.add_slide(prs.slide_layouts[5])
    slide.shapes.title.text = "Shapes"
    shapes = slide.shapes
    box = shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(0.5), Inches(1.8), Inches(2.5), Inches(1.4))
    box.text = "Default style"
    box = shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(3.5), Inches(1.8), Inches(2.5), Inches(1.4))
    box.fill.solid()
    box.fill.fore_color.rgb = RGBColor(0x2E, 0x8B, 0x57)
    box.text = "Custom green"
    shapes.add_shape(MSO_SHAPE.OVAL, Inches(6.5), Inches(1.8), Inches(2), Inches(1.4)).text = "Ellipse text"
    shapes.add_shape(MSO_SHAPE.RIGHT_ARROW, Inches(9), Inches(1.8), Inches(2), Inches(1.4))
    shapes.add_shape(MSO_SHAPE.CHEVRON, Inches(11.3), Inches(1.8), Inches(1.5), Inches(1.4))
    star = shapes.add_shape(MSO_SHAPE.STAR_5_POINT, Inches(0.8), Inches(4), Inches(1.8), Inches(1.8))
    star.fill.solid()
    star.fill.fore_color.rgb = RGBColor(0xFF, 0xC0, 0x00)
    turned = shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(3.5), Inches(4.2), Inches(2.5), Inches(1))
    turned.rotation = 20
    turned.text = "Rotated 20°"
    line = shapes.add_connector(MSO_CONNECTOR.STRAIGHT, Inches(6.5), Inches(4.2), Inches(9), Inches(6))
    line.line.width = Pt(3)
    line.line.color.rgb = RGBColor(0x40, 0x40, 0x40)
    line.line._get_or_add_ln().append(line.line._get_or_add_ln().makeelement(
        "{http://schemas.openxmlformats.org/drawingml/2006/main}tailEnd", {"type": "triangle"}))
    text = shapes.add_textbox(Inches(9.3), Inches(4), Inches(3.5), Inches(2))
    text.text_frame.word_wrap = True
    p = text.text_frame.paragraphs[0]
    p.text = "A text box with no fill. Big text:"
    run = text.text_frame.add_paragraph().add_run()
    run.text = "28 pt"
    run.font.size = Pt(28)

    slide = prs.slides.add_slide(prs.slide_layouts[5])
    slide.shapes.title.text = "Pictures"
    picture_path = os.path.join(os.path.dirname(path), "gradient.png")
    with open(picture_path, "wb") as f:
        f.write(image)
    slide.shapes.add_picture(picture_path, Inches(0.8), Inches(1.8), Inches(5.5))
    cropped = slide.shapes.add_picture(picture_path, Inches(7), Inches(1.8), Inches(4), Inches(4))
    cropped.crop_left, cropped.crop_right = 0.25, 0.25
    os.remove(picture_path)

    slide = prs.slides.add_slide(prs.slide_layouts[5])
    slide.shapes.title.text = "Table"
    rows = [("Region", "Q1", "Q2", "Q3"), ("North", "120", "135", "150"), ("South", "98", "110", "104"),
            ("East", "143", "150", "171"), ("West", "88", "95", "120")]
    table = slide.shapes.add_table(len(rows), 4, Inches(1), Inches(1.8), Inches(11), Inches(3.5)).table
    for r, row in enumerate(rows):
        for c, value in enumerate(row):
            table.cell(r, c).text = value

    slide = prs.slides.add_slide(prs.slide_layouts[5])
    slide.shapes.title.text = "Chart (not drawn yet)"
    data = CategoryChartData()
    data.categories = ["A", "B", "C"]
    data.add_series("Series 1", (3, 5, 2))
    slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(1), Inches(1.8), Inches(6), Inches(4.5), data)

    slide = prs.slides.add_slide(prs.slide_layouts[6])
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = RGBColor(0x1F, 0x2A, 0x44)
    text = slide.shapes.add_textbox(Inches(1), Inches(3), Inches(11.3), Inches(1.5))
    p = text.text_frame.paragraphs[0]
    p.text = "Dark background, white centered text"
    p.alignment = 2
    p.runs[0].font.size, p.runs[0].font.color.rgb = Pt(36), RGBColor(0xFF, 0xFF, 0xFF)

    hidden = prs.slides.add_slide(prs.slide_layouts[0])
    hidden.shapes.title.text = "HIDDEN SLIDE: must not appear"
    hidden._element.set("show", "0")
    prs.save(path)


def workbook(path):
    wb = Workbook()
    ws = wb.active
    ws.title = "Sales"
    ws.merge_cells("A1:F1")
    ws["A1"] = "Quarterly sales report"
    ws["A1"].font = Font(size=18, bold=True, color="1F4E79")
    ws["A1"].alignment = Alignment(horizontal="center")
    header = ["Date", "Product", "Units", "Price", "Share", "Notes"]
    thin = Side(style="thin", color="808080")
    for c, name in enumerate(header, start=1):
        cell = ws.cell(row=3, column=c, value=name)
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="4472C4")
        cell.alignment = Alignment(horizontal="center")
    start = datetime.date(2026, 1, 5)
    for i in range(40):
        row = 4 + i
        values = [start + datetime.timedelta(days=7 * i), f"Product {chr(65 + i % 6)}", (i * 37) % 120 + 3,
                  19.99 + i * 2.5, (i % 10) / 10, "Back-ordered, ships next week" if i % 9 == 0 else None]
        for c, value in enumerate(values, start=1):
            cell = ws.cell(row=row, column=c, value=value)
            cell.border = Border(left=thin, right=thin, top=thin, bottom=thin)
        ws.cell(row=row, column=1).number_format = "dd/mm/yyyy"
        ws.cell(row=row, column=4).number_format = '"$"#,##0.00'
        ws.cell(row=row, column=5).number_format = "0%"
        if i % 2:
            for c in range(1, 7):
                ws.cell(row=row, column=c).fill = PatternFill("solid", fgColor="DDEBF7")
    ws["F6"] = "A long note that wraps inside its cell because wrap text is turned on for it."
    ws["F6"].alignment = Alignment(wrap_text=True, vertical="top")
    for letter, width in zip("ABCDEF", (12, 14, 8, 11, 8, 30)):
        ws.column_dimensions[letter].width = width
    ws["H3"] = "This text spills over the empty cells to its right"

    wide = wb.create_sheet("Wide")
    for r in range(1, 61):
        for c in range(1, 26):
            wide.cell(row=r, column=c, value=r * c if r > 1 else f"Col {c}")
    wide.cell(row=2, column=2).value = 1234567.891
    wide.cell(row=2, column=2).number_format = "#,##0.00"

    hidden = wb.create_sheet("Hidden")
    hidden["A1"] = "HIDDEN SHEET: must not appear"
    hidden.sheet_state = "hidden"
    wb.create_sheet("Empty")

    fit = wb.create_sheet("Fit to one page")
    fit.page_setup.orientation = "landscape"
    fit.sheet_properties.pageSetUpPr.fitToPage = True
    fit.page_setup.fitToWidth, fit.page_setup.fitToHeight = 1, 1
    for r in range(1, 31):
        for c in range(1, 16):
            fit.cell(row=r, column=c, value=f"R{r}C{c}")
    wb.save(path)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    presentation(os.path.join(out, "sample.pptx"), gradient_png())
    workbook(os.path.join(out, "sample.xlsx"))
    print("Wrote", os.listdir(out))
