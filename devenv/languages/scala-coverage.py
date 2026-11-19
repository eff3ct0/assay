"""Map only reports written in this sbt run to the paths diff-cover reads."""

from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

out = Path(sys.argv[1])
reports = re.findall(
    r"Written Cobertura report \[(.+)\]",
    (out / "sbt-coverage.log").read_text(),
)
if not reports:
    sys.exit("scoverage did not write a Cobertura report")

root = ET.Element("coverage")
ET.SubElement(ET.SubElement(root, "sources"), "source").text = "."
packages = ET.SubElement(root, "packages")
for report in reports:
    tree = ET.parse(report)
    sources = [
        Path(node.text) for node in tree.findall("./sources/source")
        if node.text and node.text != "--source"
    ]
    for package in tree.findall("./packages/package"):
        for cls in package.findall("./classes/class"):
            name = Path(cls.attrib["filename"])
            matches = {(p / name).resolve() for p in sources if (p / name).is_file()}
            if len(matches) != 1:
                sys.exit(f"cannot uniquely map scoverage file {name}: {matches}")
            cls.set("filename", str(matches.pop().relative_to(Path.cwd())))
        packages.append(package)
ET.ElementTree(root).write(out / "scala-cobertura.xml", encoding="utf-8")
