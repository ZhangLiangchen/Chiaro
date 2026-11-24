"""Zero-dependency pure-Python ISOBMFF box parser for HEIC and AVIF inspection."""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple


FORBIDDEN_TMAP_PROPERTIES = frozenset({"pasp", "clap", "irot", "imir"})


@dataclass
class ISOBMFFReport:
    file_path: str
    major_brand: str = ""
    minor_version: int = 0
    compatible_brands: List[str] = field(default_factory=list)
    items: Dict[int, str] = field(default_factory=dict)  # item_id -> item_type
    dimg_refs: List[Tuple[int, List[int]]] = field(default_factory=list)
    all_refs: List[Tuple[str, int, List[int]]] = field(default_factory=list)
    groups: List[Tuple[str, int, List[int]]] = field(default_factory=list)
    ipco_properties: List[str] = field(default_factory=list)  # 1-based via index+1
    item_properties: Dict[int, List[str]] = field(default_factory=dict)
    tmap_forbidden_props: Dict[int, List[str]] = field(default_factory=dict)
    parse_errors: List[str] = field(default_factory=list)

    @property
    def item_types(self) -> List[str]:
        return list(self.items.values())

    @property
    def has_tmap_item(self) -> bool:
        return "tmap" in self.items.values()

    @property
    def has_grid_item(self) -> bool:
        return "grid" in self.items.values()

    @property
    def has_altr_group(self) -> bool:
        return any(gtype == "altr" for gtype, _, _ in self.groups)

    @property
    def has_dimg_for_tmap(self) -> bool:
        tmap_ids = {iid for iid, itype in self.items.items() if itype == "tmap"}
        return any(from_id in tmap_ids and len(to_ids) >= 2 for from_id, to_ids in self.dimg_refs)

    @property
    def has_dimg_for_grid(self) -> bool:
        grid_ids = {iid for iid, itype in self.items.items() if itype == "grid"}
        return any(from_id in grid_ids and len(to_ids) >= 2 for from_id, to_ids in self.dimg_refs)


def _iter_boxes(
    data: bytes,
    start: int,
    end: int,
    parse_errors: Optional[List[str]] = None,
    allow_size_zero_mdat: bool = False,
) -> List[Tuple[str, int, int]]:
    """Return list of (box_type, payload_start, box_end), recording malformed box errors."""
    boxes: List[Tuple[str, int, int]] = []
    pos = start
    while pos < end:
        if pos + 8 > end:
            if parse_errors is not None:
                parse_errors.append(
                    f"Truncated box header at offset {pos} ({end - pos} bytes remaining)"
                )
            break
        size = struct.unpack_from(">I", data, pos)[0]
        box_type = data[pos + 4 : pos + 8].decode("latin1", errors="replace")
        hdr = 8
        if size == 1:
            if pos + 16 > end:
                if parse_errors is not None:
                    parse_errors.append(
                        f"Truncated 64-bit box header for {box_type!r} at offset {pos}"
                    )
                break
            size = struct.unpack_from(">Q", data, pos + 8)[0]
            hdr = 16
        elif size == 0:
            if allow_size_zero_mdat and box_type == "mdat":
                size = end - pos
            else:
                if parse_errors is not None:
                    parse_errors.append(
                        f"Premature size=0 box {box_type!r} at offset {pos} "
                        f"({end - pos - 8} trailing bytes)"
                    )
                break
        if size < hdr:
            if parse_errors is not None:
                parse_errors.append(
                    f"Invalid box size {size} < {hdr} for {box_type!r} at offset {pos}"
                )
            break
        if pos + size > end:
            if parse_errors is not None:
                parse_errors.append(
                    f"Truncated box {box_type!r} at offset {pos}: "
                    f"size={size} exceeds remaining {end - pos} bytes"
                )
            break
        boxes.append((box_type, pos + hdr, pos + size))
        pos += size
    return boxes


def _parse_ftyp(data: bytes, p_start: int, p_end: int, report: ISOBMFFReport) -> None:
    if p_end - p_start < 8:
        report.parse_errors.append("ftyp box truncated")
        return
    report.major_brand = data[p_start : p_start + 4].decode("latin1", errors="replace")
    report.minor_version = struct.unpack_from(">I", data, p_start + 4)[0]
    pos = p_start + 8
    while pos + 4 <= p_end:
        report.compatible_brands.append(data[pos : pos + 4].decode("latin1", errors="replace"))
        pos += 4


def _parse_iinf(data: bytes, p_start: int, p_end: int, report: ISOBMFFReport) -> None:
    if p_end - p_start < 6:
        return
    version = data[p_start]
    pos = p_start + 4
    if version == 0:
        if pos + 2 > p_end:
            return
        pos += 2
    else:
        if pos + 4 > p_end:
            return
        pos += 4
    for btype, b_start, b_end in _iter_boxes(data, pos, p_end, report.parse_errors):
        if btype != "infe" or b_end - b_start < 8:
            continue
        infe_ver = data[b_start]
        if infe_ver in (2, 3):
            off = b_start + 4
            if infe_ver == 2:
                if off + 8 > b_end:
                    continue
                item_id = struct.unpack_from(">H", data, off)[0]
                off += 4  # item_id (2) + protection_index (2)
            else:
                if off + 10 > b_end:
                    continue
                item_id = struct.unpack_from(">I", data, off)[0]
                off += 6  # item_id (4) + protection_index (2)
            item_type = data[off : off + 4].decode("latin1", errors="replace")
            report.items[item_id] = item_type


def _parse_iref(data: bytes, p_start: int, p_end: int, report: ISOBMFFReport) -> None:
    if p_end - p_start < 4:
        return
    version = data[p_start]
    id_fmt = ">H" if version == 0 else ">I"
    id_size = 2 if version == 0 else 4
    for rtype, r_start, r_end in _iter_boxes(data, p_start + 4, p_end, report.parse_errors):
        pos = r_start
        while pos + id_size + 2 <= r_end:
            from_id = struct.unpack_from(id_fmt, data, pos)[0]
            pos += id_size
            ref_count = struct.unpack_from(">H", data, pos)[0]
            pos += 2
            if pos + ref_count * id_size > r_end:
                break
            to_ids: List[int] = []
            for _ in range(ref_count):
                to_ids.append(struct.unpack_from(id_fmt, data, pos)[0])
                pos += id_size
            report.all_refs.append((rtype, from_id, to_ids))
            if rtype == "dimg":
                report.dimg_refs.append((from_id, to_ids))


def _parse_grpl(data: bytes, p_start: int, p_end: int, report: ISOBMFFReport) -> None:
    for gtype, g_start, g_end in _iter_boxes(data, p_start, p_end, report.parse_errors):
        if g_end - g_start < 12:
            continue
        group_id = struct.unpack_from(">I", data, g_start + 4)[0]
        num_entities = struct.unpack_from(">I", data, g_start + 8)[0]
        pos = g_start + 12
        entities: List[int] = []
        for _ in range(num_entities):
            if pos + 4 > g_end:
                break
            entities.append(struct.unpack_from(">I", data, pos)[0])
            pos += 4
        report.groups.append((gtype, group_id, entities))


def _parse_iprp(data: bytes, p_start: int, p_end: int, report: ISOBMFFReport) -> None:
    ipco_props: List[str] = []
    ipma_boxes: List[Tuple[int, int]] = []
    for btype, b_start, b_end in _iter_boxes(data, p_start, p_end, report.parse_errors):
        if btype == "ipco":
            for ptype, _, _ in _iter_boxes(data, b_start, b_end, report.parse_errors):
                ipco_props.append(ptype)
        elif btype == "ipma":
            ipma_boxes.append((b_start, b_end))
    report.ipco_properties = ipco_props

    for m_start, m_end in ipma_boxes:
        if m_end - m_start < 8:
            continue
        version = data[m_start]
        flags = int.from_bytes(data[m_start + 1 : m_start + 4], "big")
        entry_count = struct.unpack_from(">I", data, m_start + 4)[0]
        pos = m_start + 8
        id_fmt = ">H" if version < 1 else ">I"
        id_size = 2 if version < 1 else 4
        large_idx = bool(flags & 1)

        for _ in range(entry_count):
            if pos + id_size + 1 > m_end:
                break
            item_id = struct.unpack_from(id_fmt, data, pos)[0]
            pos += id_size
            assoc_count = data[pos]
            pos += 1
            props_for_item = report.item_properties.setdefault(item_id, [])
            for _ in range(assoc_count):
                if large_idx:
                    if pos + 2 > m_end:
                        break
                    raw = struct.unpack_from(">H", data, pos)[0]
                    pos += 2
                    prop_index = raw & 0x7FFF
                else:
                    if pos + 1 > m_end:
                        break
                    raw = data[pos]
                    pos += 1
                    prop_index = raw & 0x7F
                if 1 <= prop_index <= len(ipco_props):
                    props_for_item.append(ipco_props[prop_index - 1])

    for item_id, item_type in report.items.items():
        if item_type == "tmap":
            bad = [p for p in report.item_properties.get(item_id, []) if p in FORBIDDEN_TMAP_PROPERTIES]
            if bad:
                report.tmap_forbidden_props[item_id] = bad


def inspect_isobmff(path: Path) -> ISOBMFFReport:
    report = ISOBMFFReport(file_path=str(path))
    try:
        data = path.read_bytes()
    except OSError as exc:
        report.parse_errors.append(f"File not found or unreadable: {exc}")
        return report
    if len(data) == 0:
        report.parse_errors.append("Empty ISOBMFF file (0 bytes)")
        return report
    for btype, b_start, b_end in _iter_boxes(
        data, 0, len(data), report.parse_errors, allow_size_zero_mdat=True
    ):
        if btype == "ftyp":
            _parse_ftyp(data, b_start, b_end, report)
        elif btype == "meta":
            if b_end - b_start < 4:
                report.parse_errors.append("meta box truncated")
                continue
            for mtype, m_start, m_end in _iter_boxes(
                data, b_start + 4, b_end, report.parse_errors
            ):
                if mtype == "iinf":
                    _parse_iinf(data, m_start, m_end, report)
                elif mtype == "iref":
                    _parse_iref(data, m_start, m_end, report)
                elif mtype == "grpl":
                    _parse_grpl(data, m_start, m_end, report)
                elif mtype == "iprp":
                    _parse_iprp(data, m_start, m_end, report)
    return report
