#!/usr/bin/env python3
"""Download the immutable public inputs used to rebuild the processed datasets."""

from __future__ import annotations

import shutil
import time
import zipfile
import hashlib
from pathlib import Path

import requests


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"

DOWNLOADS = {
    "heco_20220331_final_oahu_inputs_workbook_3_revised.xlsx": (
        "https://www.hawaiianelectric.com/documents/clean_energy_hawaii/"
        "integrated_grid_planning/20220331_final_oahu_inputs_workbook_3_revised.xlsx"
    ),
    "heco_final_oahu_inputs_workbook_1_revised.xlsx": (
        "https://www.hawaiianelectric.com/documents/clean_energy_hawaii/"
        "integrated_grid_planning/20210818_final_oahu_inputs_workbook_1_revised.xlsx"
    ),
    "heco_20220519_final_oahu_inputs_workbook_4_revised.xlsx": (
        "https://www.hawaiianelectric.com/documents/clean_energy_hawaii/"
        "integrated_grid_planning/20220519_final_oahu_inputs_workbook_4_revised.xlsx"
    ),
    "eia8602024.zip": "https://www.eia.gov/electricity/data/eia860/xls/eia8602024.zip",
    "f923_2024.zip": (
        "https://www.eia.gov/electricity/data/eia923/archive/xls/f923_2024.zip"
    ),
    "heco_2014_psip_report.pdf": (
        "https://files.hawaii.gov/puc/"
        "3_Dkt%202011-0206%202014-08-26%20HECO%20PSIP%20Report.pdf"
    ),
}

SHA256 = {
    "heco_20220331_final_oahu_inputs_workbook_3_revised.xlsx": "fec85a2efd7bbe593424944a33e5fa93c7a7080cacba3fc8d404ced7ea1eb95b",
    "heco_final_oahu_inputs_workbook_1_revised.xlsx": "4fd27568f83f09351f32072bc360dd8fc6fce3b8cb98733f02ffba8d5014bae7",
    "heco_20220519_final_oahu_inputs_workbook_4_revised.xlsx": "1c0e7077de9ec37e4de972d6457e310cca4919f554deac2ba0e43e85d9d9e473",
    "eia8602024.zip": "0aaae04812cd4ab87a3e346bdf93848a3cc15053fd4dc2a4cf82d2aeac95f12b",
    "f923_2024.zip": "272055f2d748f6486fc3076abd5a40ec736dbff45458bdb4c895761278c50f2b",
    "heco_2014_psip_report.pdf": "bf150f80762c42076fd6e6b01869158783b2ff20959ee4e9f61d9d490a3dee0f",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(name: str, url: str) -> Path:
    destination = RAW / name
    partial = destination.with_suffix(destination.suffix + ".part")
    if destination.exists() and destination.stat().st_size:
        print(f"Using existing {destination.relative_to(ROOT)}")
        actual = sha256(destination)
        if actual != SHA256[name]:
            raise ValueError(f"Checksum mismatch for {destination}: {actual}")
        return destination

    for attempt in range(1, 6):
        try:
            headers = {}
            mode = "wb"
            if partial.exists() and partial.stat().st_size:
                headers["Range"] = f"bytes={partial.stat().st_size}-"
                mode = "ab"
            with requests.get(url, headers=headers, stream=True, timeout=(30, 180)) as response:
                response.raise_for_status()
                if mode == "ab" and response.status_code != 206:
                    mode = "wb"
                with partial.open(mode) as output:
                    shutil.copyfileobj(response.raw, output, length=1024 * 1024)
            partial.replace(destination)
            actual = sha256(destination)
            if actual != SHA256[name]:
                raise ValueError(f"Checksum mismatch for {destination}: {actual}")
            print(f"Downloaded and verified {destination.relative_to(ROOT)}")
            return destination
        except requests.RequestException:
            if attempt == 5:
                raise
            time.sleep(attempt * 2)
    raise RuntimeError("unreachable")


def extract_zip(archive: Path, directory: Path) -> None:
    if directory.exists() and any(directory.iterdir()):
        print(f"Using existing {directory.relative_to(ROOT)}")
        return
    directory.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(directory)
    print(f"Extracted {directory.relative_to(ROOT)}")


def main() -> None:
    RAW.mkdir(parents=True, exist_ok=True)
    paths = {name: download(name, url) for name, url in DOWNLOADS.items()}
    extract_zip(paths["eia8602024.zip"], RAW / "eia8602024")
    extract_zip(paths["f923_2024.zip"], RAW / "eia9232024")


if __name__ == "__main__":
    main()
