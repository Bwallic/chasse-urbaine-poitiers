#!/usr/bin/env python3
"""Extrait le périmètre, les zones d'extraction et la prison d'un KMZ Google Earth."""
import json
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

NAME_MAP = {
    "Mesure de cercle": ("play-area", "perimeter", "Périmètre de jeu"),
    "France 3": ("extraction-1", "extraction", "France 3"),
    "Triangle d'or": ("extraction-2", "extraction", "Triangle d'or"),
    "parc la Cassette": ("extraction-3", "extraction", "Parc de la Cassette"),
    "Parking de la gare": ("extraction-4", "extraction", "Parking de la gare"),
    "Parc des Troenes": ("extraction-5", "extraction", "Parc des Troènes"),
    "Prison": ("prison", "prison", "Prison — Place de la Liberté"),
}
NS = {"k": "http://www.opengis.net/kml/2.2"}


def parse_coords(text):
    coords = [[float(v.split(",")[0]), float(v.split(",")[1])] for v in text.split()]
    if coords and coords[0] != coords[-1]:
        coords.append(coords[0])
    return coords


def convert(kmz_path, output_path):
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(kmz_path) as zf:
            zf.extractall(tmp)
        kml_files = list(Path(tmp).rglob("*.kml"))
        if not kml_files:
            raise RuntimeError("Aucun fichier KML trouvé dans le KMZ")
        root = ET.parse(kml_files[0]).getroot()

        features = []
        for pm in root.findall(".//k:Placemark", NS):
            name = pm.findtext("k:name", default="", namespaces=NS)
            if name not in NAME_MAP:
                continue
            feature_id, zone_type, label = NAME_MAP[name]
            line = pm.find("k:LineString", NS)
            polygon = pm.find("k:Polygon", NS)
            if line is not None:
                text = line.findtext("k:coordinates", default="", namespaces=NS)
            elif polygon is not None:
                text = polygon.findtext(".//k:outerBoundaryIs/k:LinearRing/k:coordinates", default="", namespaces=NS)
            else:
                continue
            features.append({
                "type": "Feature",
                "id": feature_id,
                "properties": {
                    "id": feature_id,
                    "zone_type": zone_type,
                    "name": label,
                    "source_name": name,
                },
                "geometry": {"type": "Polygon", "coordinates": [parse_coords(text)]},
            })

    collection = {"type": "FeatureCollection", "name": "Chasse Urbaine — Poitiers", "features": features}
    Path(output_path).write_text(json.dumps(collection, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: kmz_to_geojson.py <carte.kmz> <areas.geojson>")
    convert(sys.argv[1], sys.argv[2])
