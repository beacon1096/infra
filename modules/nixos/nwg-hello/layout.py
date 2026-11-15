from pathlib import Path
import xml.etree.ElementTree as ET


ui_path = Path("nwg_hello/ui.py")
ui = ui_path.read_text()
original = "        form_wrapper.set_size_request(monitor.get_geometry().width * 0.37, 0)"
replacement = """        def resize_panel(window, allocation):
            width = round(allocation.width * self.settings["panel-fraction"])
            if form_wrapper.get_size_request()[0] != width:
                form_wrapper.set_size_request(width, -1)

        self.window.connect("size-allocate", resize_panel)
        resize_panel(self.window, monitor.get_geometry())"""
assert ui.count(original) == 1
ui = ui.replace(original, replacement)
original = "        for session in sessions:"
replacement = """        for session in sorted(
            sessions,
            key=lambda item: item["name"] != settings.get("default-session", ""),
        ):"""
assert ui.count(original) == 1
ui_path.write_text(ui.replace(original, replacement))

template_path = Path("nwg_hello/template.glade")
tree = ET.parse(template_path)
wrapper = tree.find(".//object[@id='form-wrapper']")
content = wrapper.find("./child/object/child/object")
assert content.find("property[@name='width-request']").text == "400"
content.set("id", "form-content")
for name, value in {
    "width-request": "-1",
    "halign": "fill",
    "margin-start": "32",
    "margin-end": "32",
}.items():
    content.find(f"property[@name='{name}']").text = value
tree.write(template_path, encoding="UTF-8", xml_declaration=True)
