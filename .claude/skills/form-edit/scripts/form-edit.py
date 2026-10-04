# form-edit v1.23 — Edit 1C managed form elements (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import contextlib
import copy
import io
import json
import os
import re
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.

def parse_json_input(text, source, expected=None, inline=False):
    """Разбор пользовательского JSON: одна строка в stderr вместо traceback (issue #80).

    expected заполняем только для полиморфного входа: у файла подсказка
    была бы наполнителем — имя файла и текст парсера самодостаточны. inline печатает ещё и то,
    что доехало: у файла такого вопроса нет, он лежит на диске и его видно целиком.

    Импорты внутри тела: копия функции живёт в навыках с разными именами модулей
    (skd-decompile импортирует json локально как _json), а тело обязано быть одинаковым.
    """
    import json as _pj
    import sys as _psys
    try:
        if not str(text).strip():
            raise ValueError("input is empty")
        return _pj.loads(text)
    except ValueError as exc:
        what = "%s expects %s" % (source, expected) if expected else "Invalid JSON in %s" % source
        if inline:
            got = " ".join(str(text).split())
            label = "got"
            if not got:
                got = "(empty)"
            elif len(got) > 60:
                label = "got (first 60 chars)"
                got = got[:60]
            what = "%s, %s: %s" % (what, label, got)
        print("[ERROR] %s (%s)" % (what, exc), file=_psys.stderr)
        _psys.exit(1)


def read_json_file(path):
    """Чтение входного JSON-файла с кодировкой из BOM (issue #80).

    BOM — объявление самого файла, поэтому ему верим; без BOM ждём строгий UTF-8. Кодовую
    страницу не подбираем: угаданное имя уехало бы в метаданные молча.
    """
    import os as _pos
    import sys as _psys
    if not _pos.path.exists(path):
        print("[ERROR] File not found: %s" % path, file=_psys.stderr)
        _psys.exit(1)
    if _pos.path.isdir(path):
        print("[ERROR] Expected a JSON file, got a directory: %s" % path, file=_psys.stderr)
        _psys.exit(1)
    with open(path, "rb") as _fh:
        data = _fh.read()
    if data[:3] == b"\xef\xbb\xbf":
        return data[3:].decode("utf-8")
    if data[:2] == b"\xff\xfe":
        return data[2:].decode("utf-16-le")
    if data[:2] == b"\xfe\xff":
        return data[2:].decode("utf-16-be")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        print("[ERROR] %s is not valid UTF-8: %s - save the file as UTF-8, or add a BOM if it is UTF-16"
              % (path, exc), file=_psys.stderr)
        _psys.exit(1)


class CIDict(dict):
    # Ключи храним КАК ЕСТЬ: часть из них — имена объектов (табличные части, стандартные
    # реквизиты), они попадают в XML. Регистронезависим только поиск. Порядок вставки
    # сохраняется — от него зависит порядок эмиссии.
    def _actual(self, key):
        if not isinstance(key, str) or dict.__contains__(self, key):
            return key
        ci = self.__dict__.get('_ci')
        if ci is None or len(ci) != len(self):
            ci = {k.lower(): k for k in self if isinstance(k, str)}
            self.__dict__['_ci'] = ci
        return ci.get(key.lower(), key)

    def __getitem__(self, key):
        return dict.__getitem__(self, self._actual(key))

    def __contains__(self, key):
        return dict.__contains__(self, self._actual(key))

    def get(self, key, default=None):
        return dict.get(self, self._actual(key), default)

    def pop(self, key, *default):
        return dict.pop(self, self._actual(key), *default)

    def __setitem__(self, key, value):
        # запись по ключу, отличающемуся регистром, обновляет существующий, а не плодит дубль
        dict.__setitem__(self, self._actual(key), value)

def ci_json(obj):
    """Рекурсивно оборачивает разобранный JSON: словари → CIDict, списки обходятся."""
    if isinstance(obj, dict):
        return CIDict((k, ci_json(v)) for k, v in obj.items())
    if isinstance(obj, list):
        return [ci_json(v) for v in obj]
    return obj

def ci_parse_args(parser, argv=None):
    """parse_args по правилам PS: имена параметров и значения choices регистронезависимы."""
    argv = list(sys.argv[1:] if argv is None else argv)
    names = {s.lower(): s for a in parser._actions for s in a.option_strings}
    for i, tok in enumerate(argv):
        if tok.startswith('-') and tok.lower() in names:
            argv[i] = names[tok.lower()]
    # choices — зеркало [ValidateSet]; канонизируем ДО разбора, иначе argparse отвергнет регистр
    choice_map = {}
    for a in parser._actions:
        if a.choices:
            for s in a.option_strings:
                choice_map[s] = {str(c).lower(): c for c in a.choices}
    for i in range(len(argv) - 1):
        m = choice_map.get(argv[i])
        if m and argv[i + 1].lower() in m:
            argv[i + 1] = m[argv[i + 1].lower()]
    return parser.parse_args(argv)


# ============================================================
# Support guard (Ext/ParentConfigurations.bin) — see docs/1c-support-state-spec.md
# Blocks edits of vendor objects "на замке" / read-only configs. Trigger = bin
# present; reaction from .v8-project.json editingAllowedCheck (deny|warn|off,
# default deny). Never throws (except sys.exit on deny) — errors degrade to allow.
# ============================================================

def _sg_root_uuid(xml_path):
    if not os.path.isfile(xml_path):
        return None
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str) and child.get("uuid"):
                return child.get("uuid")
    except Exception:
        return None
    return None


def _sg_is_external_root(xml_path):
    if not os.path.isfile(xml_path):
        return False
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str):
                return child.tag.split("}")[-1] in ("ExternalDataProcessor", "ExternalReport")
    except Exception:
        return False
    return False

def _sg_find_v8project(start_dir):
    d = start_dir
    for _ in range(20):
        if not d:
            break
        pj = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pj):
            return pj
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def _sg_get_edit_mode(cfg_dir):
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(cfg_dir)
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.abspath(src)).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"


def assert_edit_allowed(target_path, require):
    try:
        rp = os.path.abspath(target_path)
        # Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
        if _sg_is_external_root(rp):
            return
        elem_uuid = _sg_root_uuid(rp)
        cfg_dir = None
        bin_path = None
        d = rp if os.path.isdir(rp) else os.path.dirname(rp)
        for _ in range(12):
            if not d:
                break
            if _sg_is_external_root(d + ".xml"):
                return
            if not elem_uuid:
                elem_uuid = _sg_root_uuid(d + ".xml")
            if not cfg_dir:
                cand = os.path.join(d, "Ext", "ParentConfigurations.bin")
                if os.path.exists(cand) or os.path.exists(os.path.join(d, "Configuration.xml")):
                    cfg_dir = d
                    bin_path = cand
            if elem_uuid and cfg_dir:
                break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if not elem_uuid and cfg_dir:
            elem_uuid = _sg_root_uuid(os.path.join(cfg_dir, "Configuration.xml"))
        if not bin_path or not os.path.exists(bin_path):
            return
        data = open(bin_path, "rb").read()
        if len(data) <= 32:
            return
        if data[:3] == b"\xef\xbb\xbf":
            data = data[3:]
        text = data.decode("utf-8", "replace")
        h = re.match(r"\{6,(\d+),(\d+),", text)
        if not h:
            return
        g = int(h.group(1))
        k = int(h.group(2))
        if k == 0:
            return
        best = None
        if elem_uuid:
            for m in re.finditer(r"([0-2]),0," + re.escape(elem_uuid.lower()), text):
                f1 = int(m.group(1))
                if best is None or f1 < best:
                    best = f1
        blocked = False
        code = ""
        reason = ""
        if g == 1:
            blocked = True
            code = "capability-off"
            reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)"
        elif require == "removed":
            if best is not None and best != 2:
                blocked = True
                code = "not-removed"
                reason = "объект не снят с поддержки — удаление сломает обновления"
        else:
            if best is not None and best == 0:
                blocked = True
                code = "locked"
                reason = "объект на замке — редактирование сломает обновления"
        if not blocked:
            return
        mode = _sg_get_edit_mode(cfg_dir)
        if mode == "off":
            return
        if mode == "warn":
            sys.stderr.write(f"[support-guard] ПРЕДУПРЕЖДЕНИЕ: {reason}. Цель: {rp}\n")
            return
        head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
        cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
        off_note = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
        if code == "capability-off":
            state = f"Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «{rp}» редактировать нельзя."
            fix = (
                "Либо снять защиту явно (навык support-edit, два шага):\n"
                f'  1. support-edit -Path "{cfg_dir}" -Capability on — включить возможность изменения (объекты пока остаются на замке);\n'
                f'  2. support-edit -Path "{rp}" -Set editable — открыть этот объект для редактирования.\n'
                "  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
            )
        elif code == "not-removed":
            state = f"Состояние: объект «{rp}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
            fix = (
                "Либо сначала снять объект с поддержки, затем удалять:\n"
                f'  support-edit -Path "{rp}" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно.'
            )
        else:
            state = f"Состояние: объект «{rp}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
            fix = (
                "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):\n"
                f'  support-edit -Path "{rp}" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);\n'
                f'  support-edit -Path "{rp}" -Set off-support — снять с поддержки: обновления по объекту больше не приходят.'
            )
        sys.stderr.write(head + "\n" + state + "\n" + cfe + "\n" + fix + "\n" + off_note + "\n")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        return


# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-FormPath", "-Path", required=True)
parser.add_argument("-JsonPath", required=True)
args = ci_parse_args(parser)

form_path = args.FormPath
json_path = args.JsonPath

# ── namespaces ───────────────────────────────────────────────

FORM_NS = "http://v8.1c.ru/8.3/xcf/logform"
V8_NS = "http://v8.1c.ru/8.1/data/core"
NS = {
    "f": FORM_NS,
    "v8": V8_NS,
}

# Все пространства имён корня формы — эмиттер пишет xsi:type, ent:, style: и др.
ALL_NS_DECL = (
    'xmlns="http://v8.1c.ru/8.3/xcf/logform"'
    ' xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
    ' xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
    ' xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"'
    ' xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema"'
    ' xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"'
    ' xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
    ' xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"'
    ' xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
    ' xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
    ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
    ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
    ' xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"'
    ' xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"'
    ' xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
    ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
)


def local_name(node):
    return etree.QName(node.tag).localname


# ── helpers ──────────────────────────────────────────────────


if not os.path.exists(form_path):
    print(f"File not found: {form_path}", file=sys.stderr)
    sys.exit(1)
if not os.path.exists(json_path):
    print(f"File not found: {json_path}", file=sys.stderr)
    sys.exit(1)

resolved_form_path = os.path.abspath(form_path)
assert_edit_allowed(resolved_form_path, "editable")
xml_parser = etree.XMLParser(remove_blank_text=False)
try:
    tree = etree.parse(resolved_form_path, xml_parser)
except etree.XMLSyntaxError as e:
    print(f"[ERROR] XML parse error: {e}")
    sys.exit(1)

root = tree.getroot()

# ── 2. Load JSON ────────────────────────────────────────────

defn = ci_json(parse_json_input(read_json_file(json_path), json_path))

# ── 3. Form name + header ───────────────────────────────────

form_name = os.path.splitext(os.path.basename(form_path))[0]
parent_dir = os.path.dirname(resolved_form_path)
if parent_dir:
    ext_dir = os.path.basename(parent_dir)
    if ext_dir == "Ext":
        form_dir = os.path.dirname(parent_dir)
        if form_dir:
            form_name = os.path.basename(form_dir)

print(f"=== form-edit: {form_name} ===")
print()

# ── 4. Scan max IDs per pool ────────────────────────────────

next_elem_id = 0
next_attr_id = 0
next_cmd_id = 0


def _scan_id(node, attr="id"):
    val = node.get(attr)
    if val and val != "-1":
        try:
            return int(val)
        except ValueError:
            pass
    return -1


# Scan element IDs
root_ci = root.find("f:ChildItems", NS)
if root_ci is not None:
    for elem in root_ci.iter():
        v = _scan_id(elem)
        if v > next_elem_id:
            next_elem_id = v

# Командная панель формы: сама (id=-1) и её кнопки — из того же пула, что и элементы
acb = root.find("f:AutoCommandBar", NS)
if acb is not None:
    for elem in acb.iter():
        v = _scan_id(elem)
        if v > next_elem_id:
            next_elem_id = v

# Scan attribute IDs (including column IDs - same pool)
for attr_el in root.findall("f:Attributes/f:Attribute", NS):
    v = _scan_id(attr_el)
    if v > next_attr_id:
        next_attr_id = v
    for col_el in attr_el.findall("f:Columns/f:Column", NS):
        v = _scan_id(col_el)
        if v > next_attr_id:
            next_attr_id = v

# Scan command IDs
for cmd_el in root.findall("f:Commands/f:Command", NS):
    v = _scan_id(cmd_el)
    if v > next_cmd_id:
        next_cmd_id = v

next_elem_id += 1
next_attr_id += 1
next_cmd_id += 1

# --- 4b. Auto-detect extension mode (BaseForm present) ---
is_extension = False
base_form = root.find("f:BaseForm", NS)
if base_form is not None:
    is_extension = True
    if next_attr_id < 1000000:
        next_attr_id = 1000000
    if next_cmd_id < 1000000:
        next_cmd_id = 1000000
    if next_elem_id < 1000000:
        next_elem_id = 1000000


def new_elem_id():
    global next_elem_id
    _id = next_elem_id
    next_elem_id += 1
    return _id


def new_attr_id():
    global next_attr_id
    _id = next_attr_id
    next_attr_id += 1
    return _id


def new_cmd_id():
    global next_cmd_id
    _id = next_cmd_id
    next_cmd_id += 1
    return _id


def new_id():
    """Id элемента — из пула элементов (у формы расширения — со сдвигом 1000000)."""
    return new_elem_id()

# ── 5. Fragment helpers (StringBuilder + Emit-* from form-compile) ──

xml_lines = []


def X(text):
    xml_lines.append(text)


# --- Type emitter ---

_FORM_TYPE_SYNONYMS = {
    "строка": "string", "число": "decimal", "булево": "boolean",
    "дата": "date", "датавремя": "dateTime",
    "number": "decimal", "bool": "boolean",
    "справочникссылка": "CatalogRef", "справочникобъект": "CatalogObject",
    "документссылка": "DocumentRef", "документобъект": "DocumentObject",
    "перечислениессылка": "EnumRef",
    "плансчетовссылка": "ChartOfAccountsRef",
    "планвидовхарактеристикссылка": "ChartOfCharacteristicTypesRef",
    "планвидоврасчётассылка": "ChartOfCalculationTypesRef",
    "планвидоврасчетассылка": "ChartOfCalculationTypesRef",
    "планобменассылка": "ExchangePlanRef",
    "бизнеспроцессссылка": "BusinessProcessRef",
    "задачассылка": "TaskRef",
    "определяемыйтип": "DefinedType",
}


# Алиас на локальный словарь: тело resolve_type_str ниже — общая реализация,
# одинаковая во всех навыках (реестр в tests/skills/check-inline-drift.mjs).
TYPE_SYNONYMS = _FORM_TYPE_SYNONYMS


def _assert_edit_unique(name, seen, ctx):
    # Уникальность имён внутри JSON-определения (1С: своя коллекция — свой неймспейс).
    if name in seen:
        print(f"[ERROR] Duplicate {ctx} '{name}' in JSON definition — names must be unique in 1C form")
        sys.exit(1)
    seen.add(name)


# ── 5b. Эмиттер элементов — общий с form-compile (эталон там; копии держит check-inline-drift) ──

_seen_element_names = set()  # пул имён элементов (глобально по всей форме)

EVENT_SUFFIX_MAP = {
    "OnChange": "\u041f\u0440\u0438\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0438",
    "StartChoice": "\u041d\u0430\u0447\u0430\u043b\u043e\u0412\u044b\u0431\u043e\u0440\u0430",
    "ChoiceProcessing": "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430\u0412\u044b\u0431\u043e\u0440\u0430",
    "AutoComplete": "\u0410\u0432\u0442\u043e\u041f\u043e\u0434\u0431\u043e\u0440",
    "Clearing": "\u041e\u0447\u0438\u0441\u0442\u043a\u0430",
    "Opening": "\u041e\u0442\u043a\u0440\u044b\u0442\u0438\u0435",
    "Click": "\u041d\u0430\u0436\u0430\u0442\u0438\u0435",
    "OnActivateRow": "\u041f\u0440\u0438\u0410\u043a\u0442\u0438\u0432\u0438\u0437\u0430\u0446\u0438\u0438\u0421\u0442\u0440\u043e\u043a\u0438",
    "BeforeAddRow": "\u041f\u0435\u0440\u0435\u0434\u041d\u0430\u0447\u0430\u043b\u043e\u043c\u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d\u0438\u044f",
    "BeforeDeleteRow": "\u041f\u0435\u0440\u0435\u0434\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u0435\u043c",
    "BeforeRowChange": "\u041f\u0435\u0440\u0435\u0434\u041d\u0430\u0447\u0430\u043b\u043e\u043c\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u044f",
    "OnStartEdit": "\u041f\u0440\u0438\u041d\u0430\u0447\u0430\u043b\u0435\u0420\u0435\u0434\u0430\u043a\u0442\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u044f",
    "OnEditEnd": "\u041f\u0440\u0438\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u0438\u0420\u0435\u0434\u0430\u043a\u0442\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u044f",
    "Selection": "\u0412\u044b\u0431\u043e\u0440\u0421\u0442\u0440\u043e\u043a\u0438",
    "OnCurrentPageChange": "\u041f\u0440\u0438\u0421\u043c\u0435\u043d\u0435\u0421\u0442\u0440\u0430\u043d\u0438\u0446\u044b",
    "TextEditEnd": "\u041e\u043a\u043e\u043d\u0447\u0430\u043d\u0438\u0435\u0412\u0432\u043e\u0434\u0430\u0422\u0435\u043a\u0441\u0442\u0430",
    "URLProcessing": "\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430\u041d\u0430\u0432\u0438\u0433\u0430\u0446\u0438\u043e\u043d\u043d\u043e\u0439\u0421\u0441\u044b\u043b\u043a\u0438",
    "DragStart": "\u041d\u0430\u0447\u0430\u043b\u043e\u041f\u0435\u0440\u0435\u0442\u0430\u0441\u043a\u0438\u0432\u0430\u043d\u0438\u044f",
    "Drag": "\u041f\u0435\u0440\u0435\u0442\u0430\u0441\u043a\u0438\u0432\u0430\u043d\u0438\u0435",
    "DragCheck": "\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430\u041f\u0435\u0440\u0435\u0442\u0430\u0441\u043a\u0438\u0432\u0430\u043d\u0438\u044f",
    "Drop": "\u041f\u043e\u043c\u0435\u0449\u0435\u043d\u0438\u0435",
    "AfterDeleteRow": "\u041f\u043e\u0441\u043b\u0435\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u044f",
}

KNOWN_EVENTS = {
    "input": ["OnChange", "StartChoice", "ChoiceProcessing", "AutoComplete", "TextEditEnd", "Clearing", "Creating", "EditTextChange"],
    "check": ["OnChange"],
    "radio": ["OnChange"],
    "label": ["Click", "URLProcessing"],
    "labelField": ["OnChange", "StartChoice", "ChoiceProcessing", "Click", "URLProcessing", "Clearing"],
    "table": ["Selection", "BeforeAddRow", "AfterDeleteRow", "BeforeDeleteRow", "OnActivateRow", "OnEditEnd", "OnStartEdit", "BeforeRowChange", "BeforeEditEnd", "ValueChoice", "OnActivateCell", "OnActivateField", "Drag", "DragStart", "DragCheck", "DragEnd", "OnGetDataAtServer", "BeforeLoadUserSettingsAtServer", "OnUpdateUserSettingSetAtServer", "OnChange"],
    "pages": ["OnCurrentPageChange"],
    "page": ["OnCurrentPageChange"],
    "button": ["Click"],
    "picField": ["OnChange", "StartChoice", "ChoiceProcessing", "Click", "Clearing"],
    "calendar": ["OnChange", "OnActivate"],
    "picture": ["Click"],
    "cmdBar": [],
    "popup": [],
    "group": [],
}

KNOWN_KEYS = {
    "group", "columnGroup", "buttonGroup", "input", "check", "radio", "label", "labelField", "table", "pages", "page",
    "button", "picture", "picField", "calendar", "cmdBar", "popup",
    "showInHeader",
    "radioButtonType", "choiceList", "columnsCount", "checkBoxType", "editMode",
    "name", "path", "title", "tooltip", "tooltipRepresentation", "extendedTooltip",
    "visible", "hidden", "enabled", "disabled", "readOnly", "userVisible",
    "events", "on", "handlers",
    "selectionMode", "showCurrentDate", "widthInMonths", "heightInMonths", "showMonthsPanel",
    "titleLocation", "representation", "width", "height",
    "horizontalStretch", "verticalStretch", "autoMaxWidth", "autoMaxHeight",
    "maxWidth", "maxHeight",
    "groupHorizontalAlign", "groupVerticalAlign", "horizontalAlign",
    "multiLine", "passwordMode", "choiceButton", "clearButton",
    "spinButton", "dropListButton", "markIncomplete", "skipOnInput", "inputHint",
    "textEdit", "choiceList",
    "wrap", "openButton", "listChoiceMode", "showInHeader", "showInFooter",
    "extendedEditMultipleValues", "chooseType", "autoCellHeight",
    "choiceButtonRepresentation", "footerHorizontalAlign", "headerHorizontalAlign",
    "headerDataPath", "headerFormat", "currentRowUse",
    "format", "editFormat", "choiceParameters", "choiceParameterLinks", "typeLink",
    "hyperlink", "formatted",
    "collapsedTitle", "showTitle", "united", "collapsed", "behavior",
    "children", "columns",
    "changeRowSet", "changeRowOrder", "autoInsertNewRow", "rowFilter", "header", "footer",
    "commandBarLocation", "searchStringLocation", "viewStatusLocation", "searchControlLocation",
    "excludedCommands",
    "pagesRepresentation",
    "type", "command", "commandName", "stdCommand", "parameter", "defaultButton", "locationInCommandBar", "displayImportance",
    "commandBar", "contextMenu", "commandSource",
    "src", "valuesPicture", "loadTransparent", "headerPicture", "footerPicture",
    "autofill",
    "choiceMode", "initialTreeView", "enableDrag", "enableStartDrag",
    "rowSelectionMode", "verticalLines", "horizontalLines",
    "rowPictureDataPath", "tableAutofill", "heightInTableRows",
    "multipleChoice", "searchOnInput", "shortcut",
    # dynamic-list table block
    "defaultItem", "useAlternationRowColor", "fileDragMode", "autoRefresh",
    "autoRefreshPeriod", "choiceFoldersAndItems", "restoreCurrentRow", "showRoot",
    "allowRootChoice", "updateOnDataChange", "allowGettingCurrentRowURL",
    "userSettingsGroup", "rowsPicture",
    # AutoCommandBar-маркер (autofill heuristic) на элементе/таблице
    "autoCmdBar",
    # дополнения командной панели таблицы (тип-ключи + свойства)
    "searchString", "viewStatus", "searchControl", "source", "horizontalLocation", "additions",
    # generic-скаляры (pass-through)
    "verticalAlign", "throughAlign", "enableContentChange", "pictureSize", "titleHeight",
    "childItemsWidth", "showLeftMargin", "cellHyperlink", "viewMode", "verticalScrollBar",
    "rowInputMode", "mask", "createButton", "fixingInTable", "verticalSpacing",
    # InputField choice-скаляры
    "choiceListButton", "quickChoice", "autoChoiceIncomplete",
    "choiceForm", "choiceHistoryOnInput", "footerDataPath", "minValue", "maxValue",
    # Button — пометка toggle-кнопки
    "checked",
    # спец-поля (документ/датчик/диаграмма) — тип-ключи + типоспец. скаляры
    "spreadsheet", "html", "textDoc", "formattedDoc", "progressBar", "trackBar",
    "chart", "ganttChart", "graphicalSchema", "planner", "periodField", "dendrogram", "ganttTable",
    "showPercent", "largeStep", "markingStep", "step",
    "horizontalScrollBar", "viewScalingMode", "output", "selectionShowMode", "protection",
    "edit", "showGrid", "showGroups", "showHeaders", "showRowAndColumnNames", "showCellNames",
    "pointerType", "drawingSelectionShowMode", "warningOnEditRepresentation", "markingAppearance",
    # report-form контекст (generic-скаляры элементов)
    "horizontalSpacing", "representationInContextMenu", "settingsNamedItemDetailedRepresentation",
    # хвост: высота элемента списка / ширина выпадающего списка / картинка кнопки выбора / прозрачный пиксель
    "itemHeight", "dropListWidth", "choiceButtonPicture", "transparentPixel",
    # хвост CI-форм: динамический заголовок / расширенное редактирование / высота таблицы
    "titleDataPath", "extendedEdit", "maxRowsCount", "autoMaxRowsCount", "heightControlVariant",
    "warningOnEdit", "nonselectedPictureText", "editTextUpdate", "footerText",
}

TYPE_KEYS = ["columnGroup", "buttonGroup", "pages", "page", "group", "input", "check", "radio", "label", "labelField", "table",
             "button", "calendar", "cmdBar", "popup", "searchString", "viewStatus", "searchControl", "picField", "picture",
             "spreadsheet", "html", "textDoc", "formattedDoc", "progressBar", "trackBar",
             "chart", "ganttChart", "graphicalSchema", "planner", "periodField", "dendrogram"]

ELEMENT_TYPE_SYNONYMS = {
    "commandBar": "cmdBar",
    "autoCommandBar": "autoCmdBar",
    "КоманднаяПанель": "cmdBar",
    "InputField": "input",
    "ПолеВвода": "input",
    "CheckBoxField": "check",
    "ПолеФлажка": "check",
    "RadioButtonField": "radio",
    "ПолеПереключателя": "radio",
    "radioButton": "radio",
    "PictureField": "picField",
    "ПолеКартинки": "picField",
    "LabelField": "labelField",
    "ПолеНадписи": "labelField",
    "CalendarField": "calendar",
    "ПолеКалендаря": "calendar",
    "LabelDecoration": "label",
    "Надпись": "label",
    "PictureDecoration": "picture",
    "Картинка": "picture",
    "UsualGroup": "group",
    "Группа": "group",
    "ОбычнаяГруппа": "group",
    "ColumnGroup": "columnGroup",
    "ГруппаКолонок": "columnGroup",
    "Pages": "pages",
    "ГруппаСтраниц": "pages",
    "Page": "page",
    "Страница": "page",
    "Table": "table",
    "Таблица": "table",
    "Button": "button",
    "Кнопка": "button",
    "Popup": "popup",
    "ВсплывающееМеню": "popup",
    # дополнения командной панели таблицы — forgiving: XML-тег/Type/рус.имя → канон
    "SearchStringAddition": "searchString",
    "SearchStringRepresentation": "searchString",
    "строкаПоиска": "searchString",
    "отображениеСтрокиПоиска": "searchString",
    "Отображение строки поиска": "searchString",
    "ViewStatusAddition": "viewStatus",
    "ViewStatusRepresentation": "viewStatus",
    "состояниеПросмотра": "viewStatus",
    "Состояние просмотра": "viewStatus",
    "SearchControlAddition": "searchControl",
    "SearchControl": "searchControl",
    "управлениеПоиском": "searchControl",
    "Управление поиском": "searchControl",
    # Спец-поля (документ/датчик) — XML-имя/рус. → канон
    "SpreadSheetDocumentField": "spreadsheet",
    "ПолеТабличногоДокумента": "spreadsheet",
    "HTMLDocumentField": "html",
    "ПолеHTMLДокумента": "html",
    "TextDocumentField": "textDoc",
    "ПолеТекстовогоДокумента": "textDoc",
    "FormattedDocumentField": "formattedDoc",
    "ПолеФорматированногоДокумента": "formattedDoc",
    "ProgressBarField": "progressBar",
    "ПолеИндикатора": "progressBar",
    "TrackBarField": "trackBar",
    "ПолеПолосыРегулирования": "trackBar",
    "ChartField": "chart",
    "ПолеДиаграммы": "chart",
    "GanttChartField": "ganttChart",
    "ПолеДиаграммыГанта": "ganttChart",
    "GraphicalSchemaField": "graphicalSchema",
    "ПолеГрафическойСхемы": "graphicalSchema",
    "PlannerField": "planner",
    "ПолеПланировщика": "planner",
    "PeriodField": "periodField",
    "ПолеПериода": "periodField",
    "DendrogramField": "dendrogram",
    "ПолеДендрограммы": "dendrogram",
}

STR_ONLY_TYPE_SYNONYMS = {"commandBar", "autoCommandBar", "КоманднаяПанель"}

PANEL_SYNONYMS = {
    'commandBar': ['commandBar', 'autoCommandBar', 'AutoCommandBar', 'autoCmdBar', 'cmdBar', 'КоманднаяПанель'],
    'contextMenu': ['contextMenu', 'ContextMenu', 'КонтекстноеМеню'],
}

REF_ROOT_SYNONYMS = {
    "Перечисление": "Enum",
    "Справочник": "Catalog",
    "Документ": "Document",
    "ПланСчетов": "ChartOfAccounts",
    "ПланВидовХарактеристик": "ChartOfCharacteristicTypes",
    "ПланВидовРасчета": "ChartOfCalculationTypes",
    "ПланВидовРасчёта": "ChartOfCalculationTypes",
    "ПланОбмена": "ExchangePlan",
    "БизнесПроцесс": "BusinessProcess",
    "Задача": "Task",
    "РегистрСведений": "InformationRegister",
    "РегистрНакопления": "AccumulationRegister",
    "РегистрБухгалтерии": "AccountingRegister",
    "РегистрРасчета": "CalculationRegister",
    "РегистрРасчёта": "CalculationRegister",
    "ЖурналДокументов": "DocumentJournal",
    "КритерийОтбора": "FilterCriterion",
}

ENUM_VALUE_SYNONYMS = {"EnumValue", "ЗначениеПеречисления"}

_FMT_MARKUP_RE = re.compile(r'</>|<\s*(?:link|b|i|u|s|color|colorStyle|bgColor|bgColorStyle|font|fontSize|fontStyle|img)(?:\s|>)', re.I)

COMPANION_STRUCT_KEYS = {
    'width', 'autoMaxWidth', 'maxWidth', 'height', 'autoMaxHeight', 'maxHeight', 'verticalAlign', 'titleHeight',
    'horizontalStretch', 'verticalStretch', 'horizontalAlign', 'groupHorizontalAlign', 'groupVerticalAlign',
    'visible', 'hidden', 'enabled', 'disabled', 'hyperlink', 'events', 'tooltip',
    'textColor', 'backColor', 'borderColor', 'font', 'border', 'цветтекста', 'цветфона', 'цветрамки', 'шрифт', 'рамка',
}

ADDITION_TYPE_MAP = {
    'searchString':  {'tag': 'SearchStringAddition',  'type': 'SearchStringRepresentation', 'suffix': 'СтрокаПоиска'},
    'viewStatus':    {'tag': 'ViewStatusAddition',    'type': 'ViewStatusRepresentation',   'suffix': 'СостояниеПросмотра'},
    'searchControl': {'tag': 'SearchControlAddition', 'type': 'SearchControl',               'suffix': 'УправлениеПоиском'},
}

ADDITION_KEY_SYNONYMS = {
    'searchString':  ['SearchStringAddition', 'SearchStringRepresentation', 'строкаПоиска', 'отображениеСтрокиПоиска'],
    'viewStatus':    ['ViewStatusAddition', 'ViewStatusRepresentation', 'состояниеПросмотра'],
    'searchControl': ['SearchControlAddition', 'SearchControl', 'управлениеПоиском'],
}

_current_table_name = {'name': None}

APPEARANCE_SPEC = {
    'titleTextColor':  ('TitleTextColor', 'color'),
    'titleBackColor':  ('TitleBackColor', 'color'),
    'titleFont':       ('TitleFont', 'font'),
    'footerTextColor': ('FooterTextColor', 'color'),
    'footerBackColor': ('FooterBackColor', 'color'),
    'footerFont':      ('FooterFont', 'font'),
    'textColor':       ('TextColor', 'color'),
    'backColor':       ('BackColor', 'color'),
    'borderColor':     ('BorderColor', 'color'),
    'border':          ('Border', 'border'),
    'font':            ('Font', 'font'),
}

APPEARANCE_SYNONYMS = {
    'цветтекста': 'textColor', 'цветфона': 'backColor', 'цветрамки': 'borderColor',
    'цветтекстазаголовка': 'titleTextColor', 'цветфоназаголовка': 'titleBackColor', 'шрифтзаголовка': 'titleFont',
    'цветтекстаподвала': 'footerTextColor', 'цветфонаподвала': 'footerBackColor', 'шрифтподвала': 'footerFont',
    'шрифт': 'font', 'рамка': 'border',
}

PROP_SYNONYMS = {
    'пометка': 'checked',
    'кнопкавыбора': 'choiceButton', 'кнопкаочистки': 'clearButton', 'кнопкарегулирования': 'spinButton',
    'кнопкавыпадающегосписка': 'dropListButton', 'кнопкасписковоговыбора': 'choiceListButton',
    'кнопкаоткрытия': 'openButton', 'кнопкапоумолчанию': 'defaultButton',
    'быстрыйвыбор': 'quickChoice', 'формавыбора': 'choiceForm', 'историявыборапривводе': 'choiceHistoryOnInput',
    'выборгруппиэлементов': 'choiceFoldersAndItems', 'фиксациявтаблице': 'fixingInTable',
    'путькданнымподвала': 'footerDataPath', 'автоотметканезаполненного': 'markIncomplete',
    'многострочныйрежим': 'multiLine', 'режимпароля': 'passwordMode', 'переноспословам': 'wrap',
    'расположениезаголовка': 'titleLocation', 'пропускатьпривводе': 'skipOnInput',
    'заголовок': 'title', 'ширина': 'width', 'высота': 'height', 'подсказкаввода': 'inputHint',
}

APP_ORDER_FIELD =['titleTextColor', 'titleBackColor', 'titleFont', 'footerTextColor', 'footerBackColor', 'footerFont', 'textColor', 'backColor', 'borderColor', 'border', 'font']

APP_ORDER_DECORATION = ['textColor', 'font', 'backColor', 'borderColor', 'border']

APP_ORDER_BUTTON = ['textColor', 'backColor', 'borderColor', 'font']

GENERIC_SCALARS = [
    ('VerticalAlign', 'verticalAlign', 'value'),
    ('ThroughAlign', 'throughAlign', 'value'),
    ('EnableContentChange', 'enableContentChange', 'bool'),
    ('PictureSize', 'pictureSize', 'value'),
    ('TitleHeight', 'titleHeight', 'value'),
    ('ChildItemsWidth', 'childItemsWidth', 'value'),
    ('ShowLeftMargin', 'showLeftMargin', 'bool'),
    ('CellHyperlink', 'cellHyperlink', 'bool'),
    ('ViewMode', 'viewMode', 'value'),
    ('VerticalScrollBar', 'verticalScrollBar', 'value'),
    ('RowInputMode', 'rowInputMode', 'value'),
    ('Mask', 'mask', 'value'),
    ('CreateButton', 'createButton', 'bool'),
    ('FixingInTable', 'fixingInTable', 'value'),
    ('VerticalSpacing', 'verticalSpacing', 'value'),
    # Spec-fields (document/gauge) - type-specific enum/bool scalars pass-through
    ('HorizontalScrollBar', 'horizontalScrollBar', 'value'),
    ('ViewScalingMode', 'viewScalingMode', 'value'),
    ('Output', 'output', 'value'),
    ('SelectionShowMode', 'selectionShowMode', 'value'),
    ('PointerType', 'pointerType', 'value'),
    ('DrawingSelectionShowMode', 'drawingSelectionShowMode', 'value'),
    ('WarningOnEditRepresentation', 'warningOnEditRepresentation', 'value'),
    ('MarkingAppearance', 'markingAppearance', 'value'),
    ('Protection', 'protection', 'bool'),
    ('Edit', 'edit', 'bool'),
    ('ShowGrid', 'showGrid', 'bool'),
    ('ShowGroups', 'showGroups', 'bool'),
    ('ShowHeaders', 'showHeaders', 'bool'),
    ('ShowRowAndColumnNames', 'showRowAndColumnNames', 'bool'),
    ('ShowCellNames', 'showCellNames', 'bool'),
    ('ShowPercent', 'showPercent', 'bool'),
    # Report-form контекст: интервал группы / представление кнопки в контекстном меню / детальное представление настройки таблицы
    ('HorizontalSpacing', 'horizontalSpacing', 'value'),
    ('RepresentationInContextMenu', 'representationInContextMenu', 'value'),
    ('SettingsNamedItemDetailedRepresentation', 'settingsNamedItemDetailedRepresentation', 'bool'),
    # Хвост: высота элемента списка (radio) / ширина выпадающего списка (input)
    ('ItemHeight', 'itemHeight', 'value'),
    ('DropListWidth', 'dropListWidth', 'value'),
    # Хвост CI-форм: динамический заголовок (Page/Group) / расширенное ред. (input) / высота таблицы по строкам
    ('TitleDataPath', 'titleDataPath', 'value'),
    ('ExtendedEdit', 'extendedEdit', 'bool'),
    ('MaxRowsCount', 'maxRowsCount', 'value'),
    ('AutoMaxRowsCount', 'autoMaxRowsCount', 'bool'),
    ('HeightControlVariant', 'heightControlVariant', 'value'),
    ('EditTextUpdate', 'editTextUpdate', 'value'),
    # Корпусный хвост: свёртка группы / форма попапа / авто-добавление / выделение отрицательных /
    # нач. позиция списка / высота списка выбора / три состояния / прокрутка страницы при сжатии
    ('ControlRepresentation', 'controlRepresentation', 'value'),
    ('ShapeRepresentation', 'shapeRepresentation', 'value'),
    ('AutoAddIncomplete', 'autoAddIncomplete', 'bool'),
    ('MarkNegatives', 'markNegatives', 'bool'),
    ('InitialListView', 'initialListView', 'value'),
    ('ChoiceListHeight', 'choiceListHeight', 'value'),
    ('ThreeState', 'threeState', 'bool'),
    ('ScrollOnCompress', 'scrollOnCompress', 'bool'),
    # Сочетание клавиш — общее свойство (команда — отдельный путь)
    ('Shortcut', 'shortcut', 'value'),
    # Батч простых скаляров (input/radio/group/picDecoration/button; Table-специфичные — отдельно)
    ('IncompleteChoiceMode', 'incompleteChoiceMode', 'value'),
    ('EqualColumnsWidth', 'equalColumnsWidth', 'bool'),
    ('ChildrenAlign', 'childrenAlign', 'value'),
    ('ImageScale', 'imageScale', 'value'),
    ('Zoomable', 'zoomable', 'bool'),
    ('Shape', 'shape', 'value'),
    ('PictureLocation', 'pictureLocation', 'value'),
    # Равная ширина элементов (check/radio) / высота заголовка пункта (radio)
    ('EqualItemsWidth', 'equalItemsWidth', 'bool'),
    ('ItemTitleHeight', 'itemTitleHeight', 'value'),
    # Спец-режим ввода текста (input, моб.: Email/PhoneNumber/...) — листовой enum-скаляр
    ('SpecialTextInputMode', 'specialTextInputMode', 'value'),
    # Ширина пункта (radio/check) / выбор нескольких значений из выпадающего (input)
    ('ItemWidth', 'itemWidth', 'value'),
    ('ShowCheckBoxesInDropList', 'showCheckBoxesInDropList', 'bool'),
    ('MultipleValueDataPath', 'multipleValueDataPath', 'value'),
    ('MultipleValuePresentDataPath', 'multipleValuePresentDataPath', 'value'),
    # Режим авто-показа кнопок открытия/очистки (input, enum)
    ('AutoShowOpenButtonMode', 'autoShowOpenButtonMode', 'value'),
    ('AutoShowClearButtonMode', 'autoShowClearButtonMode', 'value'),
    # Оформление/картинка множественного выбора (input, редко; цвета — текст-контент)
    ('MultipleValuesTextColor', 'multipleValuesTextColor', 'value'),
    ('MultipleValuesBackColor', 'multipleValuesBackColor', 'value'),
    ('MultipleValuePictureShape', 'multipleValuePictureShape', 'value'),
    ('MultipleValuePictureDataPath', 'multipleValuePictureDataPath', 'value'),
    # Хвост листовых скаляров (по 1): автокоррекция / уникальность команды / пустое множ.значение / гориз.сжатие
    ('AutoCorrectionOnTextInput', 'autoCorrectionOnTextInput', 'value'),
    ('SpellCheckingOnTextInput', 'spellCheckingOnTextInput', 'value'),
    ('CommandUniqueness', 'commandUniqueness', 'bool'),
    ('AllowInputEmptyMultipleValues', 'allowInputEmptyMultipleValues', 'bool'),
    ('BehaviorOnHorizontalCompression', 'behaviorOnHorizontalCompression', 'value'),
]

GENERIC_SCALAR_KEYS = {k for _, k, _ in GENERIC_SCALARS}

_TITLE_LOC_MAP = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom', 'auto': 'Auto'}

V8_TYPES = {
    "ValueTable": "v8:ValueTable",
    "ValueTree": "v8:ValueTree",
    "ValueList": "v8:ValueListType",
    "TypeDescription": "v8:TypeDescription",
    "Universal": "v8:Universal",
    "FixedArray": "v8:FixedArray",
    "FixedStructure": "v8:FixedStructure",
}

UI_TYPES = {
    "FormattedString": "v8ui:FormattedString",
    "Picture": "v8ui:Picture",
    "Color": "v8ui:Color",
    "Font": "v8ui:Font",
}

DCS_MAP = {
    "DataCompositionSettings": "dcsset:DataCompositionSettings",
    "DataCompositionSchema": "dcssch:DataCompositionSchema",
    "DataCompositionComparisonType": "dcscor:DataCompositionComparisonType",
}

CFG_REF_PATTERN = re.compile(
    r'^(CatalogRef|CatalogObject|DocumentRef|DocumentObject|EnumRef|'
    r'ChartOfAccountsRef|ChartOfAccountsObject|ChartOfCharacteristicTypesRef|ChartOfCharacteristicTypesObject|'
    r'ChartOfCalculationTypesRef|ChartOfCalculationTypesObject|'
    r'ExchangePlanRef|ExchangePlanObject|BusinessProcessRef|BusinessProcessObject|TaskRef|TaskObject|'
    r'InformationRegisterRecordSet|InformationRegisterRecordManager|'
    r'AccumulationRegisterRecordSet|AccountingRegisterRecordSet|'
    r'ConstantsSet|DataProcessorObject|ReportObject)\.'
)

KNOWN_INVALID_TYPES = {
    'FormDataStructure': 'Runtime type. Use object type without cfg: prefix (e.g. CatalogObject.Контрагенты, DocumentObject.Приход)',
    'FormDataCollection': 'Runtime type. Use ValueTable',
    'FormDataTree': 'Runtime type. Use ValueTree',
    'FormDataTreeItem': 'Runtime type, not valid in XML',
    'FormDataCollectionItem': 'Runtime type, not valid in XML',
    'FormGroup': 'UI element type, not a data type',
    'FormField': 'UI element type, not a data type',
    'FormButton': 'UI element type, not a data type',
    'FormDecoration': 'UI element type, not a data type',
    'FormTable': 'UI element type, not a data type',
}

_FORM_TYPE_SYNONYMS = {
    "строка": "string", "число": "decimal", "булево": "boolean",
    "дата": "date", "датавремя": "dateTime",
    "number": "decimal", "bool": "boolean",
    "справочникссылка": "CatalogRef", "справочникобъект": "CatalogObject",
    "документссылка": "DocumentRef", "документобъект": "DocumentObject",
    "перечислениессылка": "EnumRef",
    "плансчетовссылка": "ChartOfAccountsRef",
    "планвидовхарактеристикссылка": "ChartOfCharacteristicTypesRef",
    "планвидоврасчётассылка": "ChartOfCalculationTypesRef",
    "планвидоврасчетассылка": "ChartOfCalculationTypesRef",
    "планобменассылка": "ExchangePlanRef",
    "бизнеспроцессссылка": "BusinessProcessRef",
    "задачассылка": "TaskRef",
    "определяемыйтип": "DefinedType",
    "характеристика": "Characteristic",
    "любаяссылка": "AnyRef",
    "любаяссылкаиб": "AnyIBRef",
    # Платформенные v8-типы (forgiving: англ. без префикса + рус.) → каноничный с префиксом v8:
    "standardperiod": "v8:StandardPeriod",
    "стандартныйпериод": "v8:StandardPeriod",
    "standardbeginningdate": "v8:StandardBeginningDate",
    "стандартнаядатаначала": "v8:StandardBeginningDate",
    "uuid": "v8:UUID",
    "уникальныйидентификатор": "v8:UUID",
    "списокзначений": "ValueList",
}

TYPE_SYNONYMS = _FORM_TYPE_SYNONYMS

def esc_xml(s):
    # Эскейп ЗНАЧЕНИЯ АТРИБУТА: & < > и кавычка — внутри "..." литеральная " невалидна.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def esc_xml_text(s):
    # Экранирование ТЕКСТА элемента (<v8:content>, <Value>): только & < > .
    # Кавычки/апострофы в тексте 1С не экранирует (пишет литерально) — &quot; ломал бы раундтрип.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def di_attr(el):
    # DisplayImportance — атрибут открывающего тега элемента (адаптивная важность). "" если нет.
    if isinstance(el, dict) and el.get('displayImportance'):
        return f' DisplayImportance="{esc_xml(str(el["displayImportance"]))}"'
    return ''


# Базовая директория для @file-ссылок в query динсписка (устанавливается в main)
# Без -JsonPath (режим по метаданным объекта) запросов во входе нет, но база пути должна
# оставаться валидной — как и в PS-порте, где в этой ветке берётся текущий каталог.


def emit_ml_items(lines, indent, val):
    # строка → один ru-элемент; объект {lang: text} → по элементу на язык
    if isinstance(val, dict):
        for k, v in val.items():
            lines.append(f"{indent}<v8:item>")
            lines.append(f"{indent}\t<v8:lang>{k}</v8:lang>")
            lines.append(f"{indent}\t<v8:content>{esc_xml_text(str(v))}</v8:content>")
            lines.append(f"{indent}</v8:item>")
    else:
        lines.append(f"{indent}<v8:item>")
        lines.append(f"{indent}\t<v8:lang>ru</v8:lang>")
        lines.append(f"{indent}\t<v8:content>{esc_xml_text(str(val))}</v8:content>")
        lines.append(f"{indent}</v8:item>")


def emit_mltext(lines, indent, tag, text, xsi_type=None):
    attr = f' xsi:type="{xsi_type}"' if xsi_type else ''
    if not text:
        lines.append(f"{indent}<{tag}{attr}/>")
        return
    lines.append(f"{indent}<{tag}{attr}>")
    emit_ml_items(lines, f"{indent}\t", text)
    lines.append(f"{indent}</{tag}>")


def _ensure_unique(name, seen, kind):
    if name.lower() in seen:
        print(f"[ERROR] Duplicate {kind} name '{name}' — names must be unique within their collection in a 1C form (set a unique 'name')", file=sys.stderr)
        sys.exit(1)
    seen.add(name.lower())


# --- Event handler name generator ---


def normalize_panel_synonyms(el):
    if not isinstance(el, dict):
        return
    for canon, syns in PANEL_SYNONYMS.items():
        for syn in syns:
            if syn in el and isinstance(el[syn], (list, dict)):
                if syn != canon and canon not in el:
                    el[canon] = el.pop(syn)
                break


# Maps Russian/English root of typed reference path to canonical English root


def normalize_choice_value(value):
    """Returns dict {xsi_type, text} for a choiceList item value."""
    if isinstance(value, bool):
        return {"xsi_type": "xs:boolean", "text": "true" if value else "false"}
    if isinstance(value, (int, float)):
        return {"xsi_type": "xs:decimal", "text": str(value)}

    s = "" if value is None else str(value)
    if not s:
        return {"xsi_type": "xs:string", "text": ""}

    # ISO datetime ("2020-01-01T00:00:00") → xs:dateTime
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', s):
        return {"xsi_type": "xs:dateTime", "text": s}

    # Raw-ссылка по GUID (метаданные.значение) "GUID.GUID" → xr:DesignTimeRef (всегда ссылка, не строка)
    if re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[0-9a-fA-F]{8}-[0-9a-fA-F-]+', s):
        return {"xsi_type": "xr:DesignTimeRef", "text": s}

    parts = s.split(".")
    if len(parts) >= 2:
        root = parts[0]
        canon_root = None
        if root in REF_ROOT_SYNONYMS:
            canon_root = REF_ROOT_SYNONYMS[root]
        elif root in REF_ROOT_SYNONYMS.values():
            canon_root = root

        if canon_root:
            type_name = parts[1]
            normalized = None
            if canon_root == "Enum":
                if len(parts) == 3 and parts[2] == 'EmptyRef':
                    # "Enum.X.EmptyRef" — пустая ссылка, НЕ значение перечисления (без .EnumValue.)
                    normalized = f"Enum.{type_name}.EmptyRef"
                elif len(parts) == 3:
                    normalized = f"Enum.{type_name}.EnumValue.{parts[2]}"
                elif len(parts) >= 4:
                    member = parts[2]
                    if member in ENUM_VALUE_SYNONYMS:
                        rest = ".".join(parts[3:])
                    else:
                        rest = ".".join(parts[2:])
                    normalized = f"Enum.{type_name}.EnumValue.{rest}"
            else:
                if len(parts) >= 3:
                    tail = ".".join(parts[1:])
                    normalized = f"{canon_root}.{tail}"

            if normalized:
                return {"xsi_type": "xr:DesignTimeRef", "text": normalized}

    return {"xsi_type": "xs:string", "text": s}


def emit_choice_presentation(lines, pres, indent):
    """Accepts None/empty → <Presentation/>; str → ru only; dict → multi-lang."""
    if pres is None or (isinstance(pres, str) and pres == ""):
        lines.append(f"{indent}<Presentation/>")
        return

    if isinstance(pres, str):
        pairs = [("ru", pres)]
    elif isinstance(pres, dict):
        pairs = [(str(k), str(v)) for k, v in pres.items()]
    else:
        pairs = [("ru", str(pres))]

    lines.append(f"{indent}<Presentation>")
    for lang, content in pairs:
        lines.append(f"{indent}\t<v8:item>")
        lines.append(f"{indent}\t\t<v8:lang>{lang}</v8:lang>")
        lines.append(f"{indent}\t\t<v8:content>{esc_xml_text(content)}</v8:content>")
        lines.append(f"{indent}\t</v8:item>")
    lines.append(f"{indent}</Presentation>")


def choice_value_tag(norm):
    # <Value> для choiceList/choiceParameters: пустой текст → самозакрывающийся тег (зеркало платформы).
    if not norm["text"]:
        return f'<Value xsi:type="{norm["xsi_type"]}"/>'
    return f'<Value xsi:type="{norm["xsi_type"]}">{esc_xml_text(norm["text"])}</Value>'


def emit_choice_list(lines, el, indent):
    # <ChoiceList> — у RadioButtonField и InputField. Элемент: { value, presentation?/title? }.
    choice_list = el.get('choiceList') or []
    if not choice_list:
        return
    lines.append(f'{indent}<ChoiceList>')
    item_indent = f'{indent}\t'
    for item in choice_list:
        if not isinstance(item, dict):
            continue
        val_raw = item.get('value', item.get('значение'))
        has_pres = any(k in item for k in ('presentation', 'представление', 'title'))
        pres_raw = item.get('presentation', item.get('представление', item.get('title')))

        # valueType: явный xsi:type значения (системное перечисление ent:*, иной не-примитив) —
        # переопределяет авто-детект (normalize_choice_value вывела бы xs:string).
        vt_raw = item.get('valueType')
        if vt_raw == 'nil':
            norm = {'xsi_type': None, 'text': None, 'nil': True}
        elif vt_raw:
            norm = {'xsi_type': str(vt_raw), 'text': '' if val_raw is None else str(val_raw)}
        else:
            norm = normalize_choice_value(val_raw)

        if not has_pres:
            if norm.get('xsi_type') == 'xr:DesignTimeRef':
                tail = norm['text'].split('.')[-1]
                pres_raw = title_from_name(tail)
            else:
                pres_raw = norm.get('text')

        lines.append(f'{item_indent}<xr:Item>')
        val_indent = f'{item_indent}\t'
        lines.append(f'{val_indent}<xr:Presentation/>')
        lines.append(f'{val_indent}<xr:CheckState>0</xr:CheckState>')
        lines.append(f'{val_indent}<xr:Value xsi:type="FormChoiceListDesTimeValue">')
        emit_choice_presentation(lines, pres_raw, f'{val_indent}\t')
        val_tag = '<Value xsi:nil="true"/>' if norm.get('nil') else choice_value_tag(norm)
        lines.append(f'{val_indent}\t{val_tag}')
        lines.append(f'{val_indent}</xr:Value>')
        lines.append(f'{item_indent}</xr:Item>')
    lines.append(f'{indent}</ChoiceList>')


def get_el_prop(obj, names):
    # Читает свойство из dict по списку синонимов (первый найденный, иначе None).
    if not isinstance(obj, dict):
        return None
    for n in names:
        if n in obj:
            return obj[n]
    return None


def to_scalar_literal(s):
    # Литерал shorthand → тип: true/false → bool, целое/дробное → число, иначе строка.
    t = str(s).strip()
    if t.lower() == 'true':
        return True
    if t.lower() == 'false':
        return False
    if re.fullmatch(r'-?\d+', t):
        return int(t)
    if re.fullmatch(r'-?\d+\.\d+', t):
        return float(t)
    return t


def from_choice_param_shorthand(s):
    # "name=value" либо "name=v1, v2, …" (запятые → массив). → {name, value}.
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    name = s[:eq].strip()
    rest = s[eq + 1:]
    if ',' in rest:
        return {'name': name, 'value': [to_scalar_literal(p) for p in rest.split(',')]}
    return {'name': name, 'value': to_scalar_literal(rest)}


def from_choice_param_link_shorthand(s):
    # "name=dataPath" либо "name=dataPath:DontChange". → {name, dataPath, valueChange?}.
    eq = s.find('=')
    if eq < 0:
        return {'name': s.strip()}
    o = {'name': s[:eq].strip()}
    rest = s[eq + 1:].strip()
    m = re.fullmatch(r'(.*):(Clear|DontChange|очистить|неизменять)', rest, re.IGNORECASE)
    if m:
        o['dataPath'] = m.group(1).strip()
        o['valueChange'] = m.group(2)
    else:
        o['dataPath'] = rest
    return o


def from_type_link_shorthand(s):
    # "dataPath" либо "dataPath#linkItem". → {dataPath, linkItem}.
    m = re.fullmatch(r'(.*)#(\d+)', str(s))
    if m:
        return {'dataPath': m.group(1).strip(), 'linkItem': int(m.group(2))}
    return {'dataPath': str(s).strip()}


def emit_choice_param_value(lines, value, indent):
    # Внутреннее значение параметра выбора (FormChoiceListDesTimeValue): <Presentation/> + <Value>.
    # Скаляр → один Value; массив → v8:FixedArray из вложенных FormChoiceListDesTimeValue.
    lines.append(f'{indent}<Presentation/>')
    if isinstance(value, (list, tuple)):
        lines.append(f'{indent}<Value xsi:type="v8:FixedArray">')
        for v in value:
            norm = normalize_choice_value(v)
            lines.append(f'{indent}\t<v8:Value xsi:type="FormChoiceListDesTimeValue">')
            lines.append(f'{indent}\t\t<Presentation/>')
            lines.append(f'{indent}\t\t{choice_value_tag(norm)}')
            lines.append(f'{indent}\t</v8:Value>')
        lines.append(f'{indent}</Value>')
    else:
        norm = normalize_choice_value(value)
        lines.append(f'{indent}{choice_value_tag(norm)}')


def emit_choice_parameters(lines, el, indent):
    # <ChoiceParameters> (параметры выбора поля ввода) — [{name, value}]. value через
    # normalize_choice_value; массив значений → FixedArray. Рус. синонимы имя/значение.
    cp = el.get('choiceParameters') or []
    if not cp:
        return
    lines.append(f'{indent}<ChoiceParameters>')
    for item in cp:
        if isinstance(item, str):
            item = from_choice_param_shorthand(item)
        name = get_el_prop(item, ('name', 'имя'))
        has_val = isinstance(item, dict) and ('value' in item or 'значение' in item)
        val = get_el_prop(item, ('value', 'значение'))
        name_s = '' if name is None else str(name)
        lines.append(f'{indent}\t<app:item name="{esc_xml(name_s)}">')
        # Параметр выбора без значения → <app:value xsi:nil="true"/> (платформа, 13 в корпусе);
        # со значением (в т.ч. пустой строкой) → FormChoiceListDesTimeValue.
        if not has_val:
            lines.append(f'{indent}\t\t<app:value xsi:nil="true"/>')
        else:
            lines.append(f'{indent}\t\t<app:value xsi:type="FormChoiceListDesTimeValue">')
            emit_choice_param_value(lines, val, f'{indent}\t\t\t')
            lines.append(f'{indent}\t\t</app:value>')
        lines.append(f'{indent}\t</app:item>')
    lines.append(f'{indent}</ChoiceParameters>')


def emit_choice_parameter_links(lines, el, indent):
    # <ChoiceParameterLinks> (связи параметров выбора) — [{name, dataPath, valueChange?}].
    # valueChange всегда эмитится, дефолт Clear; forgiving Clear/DontChange + рус. синонимы.
    cpl = el.get('choiceParameterLinks') or []
    if not cpl:
        return
    lines.append(f'{indent}<ChoiceParameterLinks>')
    for lk in cpl:
        if isinstance(lk, str):
            lk = from_choice_param_link_shorthand(lk)
        name = get_el_prop(lk, ('name', 'имя'))
        dp = get_el_prop(lk, ('dataPath', 'path', 'путь'))
        vc_raw = get_el_prop(lk, ('valueChange', 'режимИзменения'))
        vc = 'Clear'
        if vc_raw:
            s = str(vc_raw).lower()
            if s in ('clear', 'очистить', 'очистка'):
                vc = 'Clear'
            elif s in ('dontchange', 'неизменять', 'неменять', 'нет'):
                vc = 'DontChange'
            else:
                vc = str(vc_raw)
        name_s = '' if name is None else str(name)
        dp_s = '' if dp is None else str(dp)
        lines.append(f'{indent}\t<xr:Link>')
        lines.append(f'{indent}\t\t<xr:Name>{esc_xml_text(name_s)}</xr:Name>')
        lines.append(f'{indent}\t\t<xr:DataPath xsi:type="xs:string">{esc_xml_text(dp_s)}</xr:DataPath>')
        lines.append(f'{indent}\t\t<xr:ValueChange>{vc}</xr:ValueChange>')
        lines.append(f'{indent}\t</xr:Link>')
    lines.append(f'{indent}</ChoiceParameterLinks>')


def emit_type_link(lines, el, indent):
    # <TypeLink> (связь по типу) — {dataPath, linkItem}. linkItem дефолт 0.
    tl = el.get('typeLink')
    if not tl:
        return
    if isinstance(tl, str):
        tl = from_type_link_shorthand(tl)
    dp = get_el_prop(tl, ('dataPath', 'path', 'путь'))
    li = get_el_prop(tl, ('linkItem', 'элементСвязи'))
    if li is None:
        li = 0
    dp_s = '' if dp is None else str(dp)
    lines.append(f'{indent}<TypeLink>')
    lines.append(f'{indent}\t<xr:DataPath>{esc_xml_text(dp_s)}</xr:DataPath>')
    lines.append(f'{indent}\t<xr:LinkItem>{li}</xr:LinkItem>')
    lines.append(f'{indent}</TypeLink>')


def normalize_radio_button_type(raw):
    if not raw:
        return "Auto"
    s = str(raw).strip().lower()
    if s in ("auto", "авто"):
        return "Auto"
    if s in ("radiobutton", "radiobuttons", "переключатель", "радио"):
        return "RadioButtons"
    if s in ("tumbler", "тумблер"):
        return "Tumbler"
    return str(raw).strip()


def get_handler_name(element_name, event_name):
    suffix = EVENT_SUFFIX_MAP.get(event_name)
    if suffix:
        return f"{element_name}{suffix}"
    return f"{element_name}{event_name}"


def get_element_name(el, type_key):
    if el.get('name'):
        return str(el['name'])
    return str(el.get(type_key, ''))


# Собрать упорядоченный список событий элемента (имя, обработчик) из DSL.
# Основной формат: el['events'] = { Событие: ИмяОбработчика } (None/"" → авто-имя по конвенции).
# Legacy (принимается ради совместимости): el['on'] (массив) + el['handlers'] (переопределение имён).


def get_event_pairs(el, element_name):
    pairs = []
    events = el.get('events')
    if events:
        for ev_name, val in events.items():
            # Значение — имя обработчика; null — имя по шаблону; объект { handler, callType } или массив
            # таких объектов (в расширении на одно событие вешают и Before, и After)
            for v in (val if isinstance(val, list) else [val]):
                if isinstance(v, dict):
                    handler = '' if v.get('handler') is None else str(v.get('handler'))
                    call_type = normalize_call_type(v.get('callType'), element_name, ev_name)
                else:
                    handler = '' if v is None else str(v)
                    call_type = ''
                if not handler:
                    handler = get_handler_name(element_name, ev_name)
                pairs.append((ev_name, handler, call_type))
    elif el.get('on'):
        handlers = el.get('handlers') or {}
        for evt in (el['on'] if isinstance(el['on'], list) else [el['on']]):
            if isinstance(evt, dict):
                evt_name = str(evt.get('event', ''))
                handler = '' if evt.get('handler') is None else str(evt.get('handler'))
                call_type = normalize_call_type(evt.get('callType'), element_name, evt_name)
            else:
                evt_name, handler, call_type = str(evt), '', ''
            if not handler:
                handler = str(handlers[evt_name]) if handlers.get(evt_name) else get_handler_name(element_name, evt_name)
            pairs.append((evt_name, handler, call_type))
    return pairs


# Вид вызова обработчика в расширении: Before / After / Override (регистр не важен); пусто — не указан.


def normalize_call_type(raw, element_name, event_name):
    if raw is None or str(raw) == '':
        return ''
    for v in ('Before', 'After', 'Override'):
        if str(raw).lower() == v.lower():
            return v
    print(f"[ERROR] Element '{element_name}', event '{event_name}': callType '{raw}' — expected Before, After or Override", file=sys.stderr)
    sys.exit(1)


# Проверить, подключено ли событие к элементу (в любом из форматов).


def emit_events(lines, el, element_name, indent, type_key):
    pairs = get_event_pairs(el, element_name)
    if not pairs:
        return

    # Validate event names
    if type_key and type_key in KNOWN_EVENTS:
        allowed = KNOWN_EVENTS[type_key]
        for ev_name, _, _ in pairs:
            if allowed and str(ev_name) not in allowed:
                print(f"[WARN] Unknown event '{ev_name}' for {type_key} '{element_name}'. Known: {', '.join(allowed)}")

    lines.append(f"{indent}<Events>")
    for ev_name, handler, call_type in pairs:
        ct_attr = f' callType="{call_type}"' if call_type else ''
        lines.append(f'{indent}\t<Event name="{ev_name}"{ct_attr}>{handler}</Event>')
    lines.append(f"{indent}</Events>")


# Детектор «настоящей» inline-разметки (1С: <link>/<b>/<color>/… и </>). Должен быть
# идентичен form-decompile/form-compile.ps1, иначе гибрид-раундтрип поедет.


def _has_real_markup(text):
    if text is None:
        return False
    vals = list(text.values()) if isinstance(text, dict) else [text]
    return any(_FMT_MARKUP_RE.search(str(v)) for v in vals)


def resolve_ml_formatted(val):
    # {text, formatted} = явный override; строка/мапа → авто-детект formatted
    if isinstance(val, dict) and 'text' in val:
        return val['text'], bool(val.get('formatted'))
    return val, _has_real_markup(val)


# ExtendedTooltip — это LabelDecoration: own-content (layout/оформление/флаги/hyperlink) ±текст.
# Признак структурированной формы: объект с любым НЕ-текстовым ключом ({text,formatted}/{ru,en} → текст).


def emit_companion_title(lines, content, indent):
    text, fmt = resolve_ml_formatted(content)
    lines.append(f'{indent}<Title formatted="{"true" if fmt else "false"}">')
    emit_ml_items(lines, f'{indent}\t', text)
    lines.append(f'{indent}</Title>')


def emit_companion(lines, tag, name, indent, content=None):
    cid = new_id()
    has_content = content is not None and not (isinstance(content, str) and content == '')
    if not has_content:
        lines.append(f'{indent}<{tag} name="{name}" id="{cid}"/>')
        return
    inner = f'{indent}\t'
    # DI-Attr от собственного объекта компаньона (не от владельца) — зеркало ps1
    lines.append(f'{indent}<{tag} name="{name}" id="{cid}"{di_attr(content if isinstance(content, dict) else None)}>')
    if isinstance(content, dict) and any(k in content for k in COMPANION_STRUCT_KEYS):
        # own-content ПЕРЕД Title (в корпусе layout-first 582 vs 10).
        emit_common_flags(lines, content, inner)
        if content.get('hyperlink') is True:
            lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
        emit_layout(lines, content, inner)
        emit_appearance(lines, content, inner, 'decoration')
        if 'text' in content:
            emit_companion_title(lines, content, inner)
        # ToolTip компаньона (подсказка самой расширенной подсказки) — после Title (порядок схемы LabelDecoration)
        if content.get('tooltip'):
            emit_mltext(lines, inner, 'ToolTip', content['tooltip'])
        # События компаньона (ExtendedTooltip = LabelDecoration: напр. URLProcessing у hyperlink-подсказки)
        emit_events(lines, content, name, inner, 'label')
    else:
        emit_companion_title(lines, content, inner)
    lines.append(f'{indent}</{tag}>')


def emit_companion_panel(lines, tag, name, indent, panel):
    # Companion-командная-панель (ContextMenu/AutoCommandBar) с контентом: { autofill?, horizontalAlign?, children?[] }
    # или массив = shorthand для { children }. Пусто/нет → self-closing.
    cid = new_id()
    autofill = None
    halign = None
    children = None
    if isinstance(panel, list):
        children = panel
    elif panel is not None:
        if panel.get('autofill') is not None:
            autofill = bool(panel.get('autofill'))
        if panel.get('horizontalAlign'):
            halign = str(panel.get('horizontalAlign'))
        children = panel.get('children')
    has_children = bool(children) and len(children) > 0
    # Платформа пишет <Autofill> только при false; true = дефолт (тег опускается).
    emit_af_false = (autofill is False)
    if not emit_af_false and not has_children and not halign:
        lines.append(f'{indent}<{tag} name="{name}" id="{cid}"/>')
        return
    lines.append(f'{indent}<{tag} name="{name}" id="{cid}"{di_attr(panel if isinstance(panel, dict) else None)}>')
    if halign:
        lines.append(f'{indent}\t<HorizontalAlign>{halign}</HorizontalAlign>')
    if emit_af_false:
        lines.append(f'{indent}\t<Autofill>false</Autofill>')
    if has_children:
        lines.append(f'{indent}\t<ChildItems>')
        for c in children:
            emit_element(lines, c, f'{indent}\t\t', in_cmd_bar=True)
        lines.append(f'{indent}\t</ChildItems>')
    lines.append(f'{indent}</{tag}>')


# Дополнения командной панели таблицы: тип DSL → XML-тег + AdditionSource.Type + суффикс имени.


def get_hlocation(el):
    # HorizontalLocation: auto (дефолт, опускаем) / left / right; forgiving + рус.
    if not isinstance(el, dict):
        return None
    v = el.get('horizontalLocation')
    if not v:
        return None
    s = str(v).lower()
    if s in ('auto', 'авто'):
        return None
    if s in ('left', 'слева', 'лево'):
        return 'Left'
    if s in ('right', 'справа', 'право'):
        return 'Right'
    if s in ('center', 'центр', 'по центру'):
        return 'Center'
    return str(v)


def emit_addition_body(lines, props, source, src_type, add_name, indent):
    # Тело дополнения: AdditionSource + свойства (как у поля) + companions. props может быть None.
    inner = f'{indent}\t'
    lines.append(f'{inner}<AdditionSource>')
    lines.append(f'{inner}\t<Item>{source}</Item>')
    lines.append(f'{inner}\t<Type>{src_type}</Type>')
    lines.append(f'{inner}</AdditionSource>')
    if props:
        if props.get('title'):
            emit_mltext(lines, inner, 'Title', props['title'])
        emit_common_flags(lines, props, inner)
        if props.get('tooltip'):
            emit_mltext(lines, inner, 'ToolTip', props['tooltip'])
        if props.get('tooltipRepresentation'):
            lines.append(f'{inner}<ToolTipRepresentation>{props["tooltipRepresentation"]}</ToolTipRepresentation>')
        hl = get_hlocation(props)
        if hl:
            lines.append(f'{inner}<HorizontalLocation>{hl}</HorizontalLocation>')
        emit_layout(lines, props, inner)
        emit_appearance(lines, props, inner, 'field')
    emit_companion(lines, 'ContextMenu', f'{add_name}КонтекстноеМеню', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{add_name}РасширеннаяПодсказка', inner)


def emit_addition(lines, el, name, eid, type_key, indent):
    # Кастомное дополнение (тип-элемент в commandBar): source дефолтит в текущую таблицу.
    m = ADDITION_TYPE_MAP[type_key]
    source = el.get('source') or _current_table_name['name'] or ''
    lines.append(f'{indent}<{m["tag"]} name="{name}" id="{eid}"{di_attr(el)}>')
    emit_addition_body(lines, el, source, m['type'], name, indent)
    lines.append(f'{indent}</{m["tag"]}>')


def emit_table_addition(lines, type_key, table_name, indent, override=None):
    # Стандартное табличное дополнение (авто-генерация). override — объект отклонений из карты additions.
    m = ADDITION_TYPE_MAP[type_key]
    add_name = f'{table_name}{m["suffix"]}'
    aid = new_id()
    lines.append(f'{indent}<{m["tag"]} name="{add_name}" id="{aid}">')
    emit_addition_body(lines, override, table_name, m['type'], add_name, indent)
    lines.append(f'{indent}</{m["tag"]}>')


def get_addition_override(additions, type_key):
    # Прочитать override-объект для типа из per-table карты additions (с синонимами).
    if not isinstance(additions, dict):
        return None
    for k in [type_key] + ADDITION_KEY_SYNONYMS[type_key]:
        if k in additions:
            return additions[k]
    return None


# Role-adjustable boolean (xr:Common + 0..N xr:Value name="Role.X").
# Единый механизм платформы: UserVisible (элементы), View/Edit (атрибуты), Use (команды/кнопки).
# Значение DSL: скаляр bool → только <xr:Common>; объект { common, roles:{ Имя: bool } } → +пер-ролевые исключения.
# Имя роли принимаем с/без префикса "Role." (forgiving); на выход всегда с префиксом.


def emit_xr_flag(lines, tag, val, indent):
    if val is None:
        return
    if isinstance(val, bool):
        lines.append(f"{indent}<{tag}>")
        lines.append(f"{indent}\t<xr:Common>{'true' if val else 'false'}</xr:Common>")
        lines.append(f"{indent}</{tag}>")
        return
    # объектная форма { common, roles }
    common = bool(val.get('common')) if val.get('common') is not None else False
    lines.append(f"{indent}<{tag}>")
    lines.append(f"{indent}\t<xr:Common>{'true' if common else 'false'}</xr:Common>")
    roles = val.get('roles')
    if roles:
        for rname, rval in roles.items():
            # Forgiving: имя без префикса, с "Role." или кириллическим "Роль." → нормализуем в "Role.".
            # Роль по GUID (заимствованная/расширение — name="<guid>" без префикса) эмитим как есть.
            rn = re.sub(r'^(Role|Роль)\.', '', rname)
            if not re.match(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', rn):
                rn = "Role." + rn
            lines.append(f"{indent}\t<xr:Value name=\"{rn}\">{'true' if rval else 'false'}</xr:Value>")
    lines.append(f"{indent}</{tag}>")


def emit_common_flags(lines, el, indent):
    if el.get('visible') is False or el.get('hidden') is True:
        lines.append(f"{indent}<Visible>false</Visible>")
    if el.get('userVisible') is not None:
        emit_xr_flag(lines, 'UserVisible', el.get('userVisible'), indent)
    if el.get('enabled') is False or el.get('disabled') is True:
        lines.append(f"{indent}<Enabled>false</Enabled>")
    if el.get('readOnly') is True:
        lines.append(f"{indent}<ReadOnly>true</ReadOnly>")


# Общие свойства элемента (любой тип, включая Button/cmdBar): default/skip/drag.


def emit_common_element_props(lines, el, indent):
    if el.get('defaultItem') is True:
        lines.append(f"{indent}<DefaultItem>true</DefaultItem>")
    if 'skipOnInput' in el and el['skipOnInput'] is not None:
        siv = 'true' if el['skipOnInput'] is True else 'false'
        lines.append(f"{indent}<SkipOnInput>{siv}</SkipOnInput>")
    # EnableStartDrag — фактическое значение (платформа эмитит и явный false, напр. SpreadSheet)
    if el.get('enableStartDrag') is not None:
        lines.append(f'{indent}<EnableStartDrag>{"true" if el["enableStartDrag"] else "false"}</EnableStartDrag>')
    if el.get('fileDragMode'):
        lines.append(f"{indent}<FileDragMode>{el['fileDragMode']}</FileDragMode>")
    # Cell-свойства поля в таблице (общие для Input/Label/Picture/CheckBox): захват «как есть»
    for key, tag in (('showInHeader', 'ShowInHeader'), ('showInFooter', 'ShowInFooter'), ('autoCellHeight', 'AutoCellHeight')):
        if el.get(key) is not None:
            lines.append(f'{indent}<{tag}>{"true" if el[key] else "false"}</{tag}>')
    # Динамический заголовок колонки-группы из данных (HeaderDataPath) — перед HeaderHorizontalAlign (порядок XSD)
    if el.get('headerDataPath'):
        lines.append(f"{indent}<HeaderDataPath>{esc_xml_text(str(el['headerDataPath']))}</HeaderDataPath>")
    if el.get('footerHorizontalAlign'):
        lines.append(f"{indent}<FooterHorizontalAlign>{el['footerHorizontalAlign']}</FooterHorizontalAlign>")
    if el.get('headerHorizontalAlign'):
        lines.append(f"{indent}<HeaderHorizontalAlign>{el['headerHorizontalAlign']}</HeaderHorizontalAlign>")
    # Формат заголовка колонки-группы (ML-текст) — после HeaderHorizontalAlign (порядок XSD)
    if el.get('headerFormat'):
        emit_mltext(lines, indent, 'HeaderFormat', el['headerFormat'])


def emit_picture_ref(lines, val, pic_tag, indent):
    """Картинка-ссылка с прозрачностью (HeaderPicture/FooterPicture/ValuesPicture/Page Picture).
    Платформа ВСЕГДА эмитит <xr:LoadTransparent> → пишем всегда (false по умолчанию).
    Значение: скаляр (Ref) ИЛИ объект {src, loadTransparent, transparentPixel}.
    src с префиксом "abs:" → встроенная картинка <xr:Abs>; иначе <xr:Ref>."""
    if not val:
        return
    tpx = None
    if isinstance(val, str):
        src, lt = val, False
    else:
        src = val.get('src')
        lt = val.get('loadTransparent') is True
        tpx = val.get('transparentPixel')
    if not src:
        return
    src_str = str(src)
    lines.append(f"{indent}<{pic_tag}>")
    if src_str.startswith('abs:'):
        lines.append(f"{indent}\t<xr:Abs>{esc_xml_text(src_str[4:])}</xr:Abs>")
    else:
        lines.append(f"{indent}\t<xr:Ref>{esc_xml_text(src_str)}</xr:Ref>")
    lines.append(f'{indent}\t<xr:LoadTransparent>{"true" if lt else "false"}</xr:LoadTransparent>')
    if tpx:
        lines.append(f'{indent}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
    lines.append(f"{indent}</{pic_tag}>")


def emit_column_pics(lines, el, indent):
    """Картинки заголовка/подвала колонки поля — по схеме сразу после <EditMode>,
    перед тип-специфичными элементами и layout (порядок XDTO строгий именно здесь)."""
    emit_picture_ref(lines, el.get('headerPicture'), 'HeaderPicture', indent)
    emit_picture_ref(lines, el.get('footerPicture'), 'FooterPicture', indent)


def emit_command_picture(lines, pic, elem_lt, indent):
    """<Picture> кнопки/попапа/команды. Дефолт LoadTransparent=true, отклонение false
    (обратная конвенция относительно header/values-картинок). Прощающий ввод:
    принимает скаляр (Ref) ИЛИ объект {src, loadTransparent} — на случай если модель
    опишет картинку объектно по аналогии с headerPicture. elem_lt — legacy
    элемент-уровневый ключ loadTransparent (если в объекте флаг не задан)."""
    if not pic:
        return
    lt = None
    tpx = None
    if isinstance(pic, str):
        src = pic
    else:
        src = pic.get('src')
        if pic.get('loadTransparent') is not None:
            lt = bool(pic.get('loadTransparent'))
        tpx = pic.get('transparentPixel')
    if not src:
        return
    if lt is None and elem_lt is not None:
        lt = bool(elem_lt)
    src_str = str(src)
    lines.append(f'{indent}<Picture>')
    if src_str.startswith('abs:'):
        lines.append(f'{indent}\t<xr:Abs>{esc_xml_text(src_str[4:])}</xr:Abs>')
    else:
        lines.append(f'{indent}\t<xr:Ref>{esc_xml_text(src_str)}</xr:Ref>')
    lines.append(f'{indent}\t<xr:LoadTransparent>{"false" if lt is False else "true"}</xr:LoadTransparent>')
    if tpx:
        lines.append(f'{indent}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
    lines.append(f'{indent}</Picture>')


# --- Оформление элемента: цвета / шрифты / граница (зеркало form-compile.ps1 Emit-Appearance) ---
# Прямые свойства элемента (<TextColor>/<Font>/<Border> + header/footer у полей). Ключи англ.
# camelCase 1:1 с тегами + приём рус. синонимов. Цвет — verbatim-строка (style:/web:/win:/#RRGGBB);
# шрифт — строка-ref/объект-атрибуты; граница — строка-ref/
# объект {width,style}. Порядок тегов — XSD (профиль по базовому типу).


def get_appearance_value(el, canonical):
    if not isinstance(el, dict):
        return None
    if canonical in el:
        return el[canonical]
    lowmap = {k.lower(): k for k in el.keys()}
    if canonical.lower() in lowmap:
        return el[lowmap[canonical.lower()]]
    for syn, canon in APPEARANCE_SYNONYMS.items():
        if canon == canonical and syn in lowmap:
            return el[lowmap[syn]]
    return None


def emit_font_tag(lines, tag, val, indent):
    if isinstance(val, str):
        lines.append(f'{indent}<{tag} ref="{esc_xml(val)}" kind="StyleItem"/>')
        return
    attrs = []
    for a in ('ref', 'faceName', 'height', 'bold', 'italic', 'underline', 'strikeout', 'kind', 'scale'):
        if a in val and val[a] is not None:
            v = val[a]
            if isinstance(v, bool):
                v = 'true' if v else 'false'
            attrs.append(f'{a}="{esc_xml(str(v))}"')
    lines.append(f'{indent}<{tag} {" ".join(attrs)}/>')


def emit_border_tag(lines, val, indent):
    if isinstance(val, str):
        lines.append(f'{indent}<Border ref="{esc_xml(val)}"/>')
        return
    if val.get('ref'):
        lines.append(f'{indent}<Border ref="{esc_xml(str(val["ref"]))}"/>')
        return
    width = val['width'] if val.get('width') is not None else 1
    style = str(val['style']) if 'style' in val else None
    lines.append(f'{indent}<Border width="{width}">')
    if style:
        lines.append(f'{indent}\t<v8ui:style xsi:type="v8ui:ControlBorderType">{esc_xml_text(style)}</v8ui:style>')
    lines.append(f'{indent}</Border>')


# ─────────────────────────────────────────────────────────────────────────────
# Planner design-time <Settings xsi:type="pl:Planner"> — зеркало Emit-PlannerSettings (ps1).


def emit_appearance(lines, el, indent, profile='field'):
    if not isinstance(el, dict):
        return
    order = {'decoration': APP_ORDER_DECORATION, 'button': APP_ORDER_BUTTON}.get(profile, APP_ORDER_FIELD)
    for key in order:
        val = get_appearance_value(el, key)
        if val is None or (isinstance(val, str) and val == ''):
            continue
        tag, kind = APPEARANCE_SPEC[key]
        if kind == 'color':
            lines.append(f'{indent}<{tag}>{esc_xml_text(str(val))}</{tag}>')
        elif kind == 'font':
            emit_font_tag(lines, tag, val, indent)
        else:
            emit_border_tag(lines, val, indent)


# Простые скаляры элемента (pass-through, зеркало $script:genericScalars). kind bool/value.


def emit_generic_scalars(lines, el, indent):
    for tag, key, kind in GENERIC_SCALARS:
        if key not in el or el[key] is None:
            continue
        if kind == 'bool':
            lines.append(f'{indent}<{tag}>{"true" if el[key] else "false"}</{tag}>')
        else:
            v = str(el[key])
            if v == '':
                continue
            lines.append(f'{indent}<{tag}>{esc_xml_text(v)}</{tag}>')


def emit_layout(lines, el, indent, skip_height=False, multi_line_default=False):
    # Общие layout-свойства — применимы ко всем элементам. Порядок согласован
    # с историческим выводом input/label, чтобы не сдвигать существующие снапшоты.
    # skip_height: подавить <Height> (зарезервирован; Table теперь эмитит <Height> generic-ом + свой <HeightInTableRows>).
    # multi_line_default: input без явного autoMaxWidth при multiLine → AutoMaxWidth=false.
    # CommandSet (отключённые команды редактора) — общее свойство поля; в схеме рано (после TitleLocation).
    if el.get('excludedCommands') and len(el['excludedCommands']) > 0:
        lines.append(f'{indent}<CommandSet>')
        for cmd in el['excludedCommands']:
            lines.append(f'{indent}\t<ExcludedCommand>{cmd}</ExcludedCommand>')
        lines.append(f'{indent}</CommandSet>')
    emit_common_element_props(lines, el, indent)
    if 'autoMaxWidth' in el:
        if el.get('autoMaxWidth') is False:
            lines.append(f"{indent}<AutoMaxWidth>false</AutoMaxWidth>")
    elif multi_line_default:
        lines.append(f"{indent}<AutoMaxWidth>false</AutoMaxWidth>")
    if el.get('maxWidth') is not None:
        lines.append(f"{indent}<MaxWidth>{el['maxWidth']}</MaxWidth>")
    if el.get('autoMaxHeight') is False:
        lines.append(f"{indent}<AutoMaxHeight>false</AutoMaxHeight>")
    if el.get('maxHeight') is not None:
        lines.append(f"{indent}<MaxHeight>{el['maxHeight']}</MaxHeight>")
    if el.get('width'):
        lines.append(f"{indent}<Width>{el['width']}</Width>")
    if not skip_height and el.get('height'):
        lines.append(f"{indent}<Height>{el['height']}</Height>")
    if el.get('horizontalStretch') is not None:
        lines.append(f'{indent}<HorizontalStretch>{"true" if el["horizontalStretch"] else "false"}</HorizontalStretch>')
    if el.get('verticalStretch') is not None:
        lines.append(f'{indent}<VerticalStretch>{"true" if el["verticalStretch"] else "false"}</VerticalStretch>')
    if el.get('groupHorizontalAlign'):
        lines.append(f"{indent}<GroupHorizontalAlign>{el['groupHorizontalAlign']}</GroupHorizontalAlign>")
    if el.get('groupVerticalAlign'):
        lines.append(f"{indent}<GroupVerticalAlign>{el['groupVerticalAlign']}</GroupVerticalAlign>")
    if el.get('horizontalAlign'):
        lines.append(f"{indent}<HorizontalAlign>{el['horizontalAlign']}</HorizontalAlign>")
    emit_generic_scalars(lines, el, indent)


def title_from_name(name):
    """СуммаДокумента → 'Сумма документа'. НДСВключен → 'НДС включен'."""
    if not name:
        return ''
    s = re.sub(r'([А-ЯA-Z])([А-ЯA-Z][а-яa-z])', r'\1 \2', name)
    s = re.sub(r'([а-яa-z0-9])([А-ЯA-Z])', r'\1 \2', s)
    parts = s.split(' ')
    if not parts:
        return s
    out = [parts[0]]
    for p in parts[1:]:
        out.append(p if (len(p) > 1 and p.isupper()) else p.lower())
    return ' '.join(out)


def emit_title(lines, el, name, indent, auto=False):
    # Нет ключа title → авто-вывод из имени (помощь модели).
    # Явный title "" (или None) → подавить. Явный непустой → как есть.
    if 'title' in el:
        if el.get('title'):
            emit_mltext(lines, indent, 'Title', el['title'])
    elif auto and name:
        emit_mltext(lines, indent, 'Title', title_from_name(name))
    # ToolTip элемента (всплывающая подсказка) — по схеме сразу после Title.
    if el.get('tooltip'):
        emit_mltext(lines, indent, 'ToolTip', el['tooltip'])
    # ToolTipRepresentation — режим показа подсказки (None/Button/ShowBottom/…), после ToolTip.
    if el.get('tooltipRepresentation'):
        lines.append(f'{indent}<ToolTipRepresentation>{el["tooltipRepresentation"]}</ToolTipRepresentation>')


def map_title_loc(v):
    return _TITLE_LOC_MAP.get(str(v).lower(), str(v))


def emit_title_location(lines, el, indent, smart_default):
    # Нет ключа → умный дефолт (Right/None), эмитится. "" → подавить (дефолт платформы).
    # Значение → эмитить с маппингом регистра.
    if 'titleLocation' in el:
        if el.get('titleLocation'):
            lines.append(f"{indent}<TitleLocation>{map_title_loc(el['titleLocation'])}</TitleLocation>")
    elif smart_default:
        lines.append(f"{indent}<TitleLocation>{smart_default}</TitleLocation>")


# --- Type emitter ---


def resolve_type_str(type_str):
    if not type_str:
        return type_str
    # Прощающий ввод: ведущий префикс приходит копипастой из выгрузки. Без срезания он ломает
    # поиск в словаре — русское имя типа остаётся непереведённым, и платформа отвечает
    # «Неизвестное имя типа». cfg: снимаем всегда — он однозначно означает текущую конфигурацию.
    # Сгенерированный dNpM: (в корпусе на этом URI встречаются d4p1, d5p1, d6p1 — имя префикса
    # платформа выдаёт по порядку объявления) снимаем ТОЛЬКО у ссылочных типов, с точкой:
    # сам по себе префикс многозначен — в формах d5p1:Chart, d5p1:TextDocument,
    # d5p1:GeographicalSchema адресуют чужие пространства имён, и там он часть значения.
    if type_str.startswith('cfg:'):
        type_str = type_str[4:]
    elif '.' in type_str and re.match(r'^d\d+p\d+:', type_str):
        type_str = type_str[type_str.index(':') + 1:]
    # Хвосты, которые дописывает вывод meta-info к множествам типов: суффикс обобщённого метатипа
    # и счётчик состава. Копипаста строки оттуда — обычный путь, поэтому хвост снимаем молча.
    # Срезаем ТОЛЬКО эти известные формы: круглые скобки заняты параметризованными типами
    # (Число(15,2)), слепой срез скобок сломал бы их.
    type_str = re.sub(r'\s*\((?:все|all)\)\s*$', '', type_str, flags=re.IGNORECASE).strip()
    type_str = re.sub(r'\s*[—-]\s*(?:типов|types):\s*\d+\s*$', '', type_str, flags=re.IGNORECASE).strip()
    type_str = re.sub(r'\s*\((?:типов|types):\s*\d+\)\s*$', '', type_str, flags=re.IGNORECASE).strip()
    # Параметризованные типы: Number(15,2), Строка(100)
    m = re.match(r'^([^(]+)\((.+)\)$', type_str)
    if m:
        base_name = m.group(1).strip()
        params = m.group(2)
        resolved = TYPE_SYNONYMS.get(base_name.lower())
        if resolved:
            return f'{resolved}({params})'
        return type_str
    # Ссылочные типы: СправочникСсылка.Организации -> CatalogRef.Организации
    if '.' in type_str:
        dot_idx = type_str.index('.')
        prefix = type_str[:dot_idx]
        suffix = type_str[dot_idx:]  # includes the dot
        resolved = TYPE_SYNONYMS.get(prefix.lower())
        if resolved:
            return f'{resolved}{suffix}'
        return type_str
    # Простое имя
    resolved = TYPE_SYNONYMS.get(type_str.lower())
    if resolved:
        return resolved
    return type_str


def emit_single_type(lines, type_str, indent):
    type_str = resolve_type_str(type_str)
    # TypeId — тип, заданный глобальным стабильным GUID (<v8:TypeId>, не <v8:Type>). Платформа так
    # сериализует типы, чьё имя в этом контексте недоступно (определяемые/характеристики). GUID
    # глобально стабилен → эмитим verbatim (как роль-по-GUID). Маркер декомпилятора: 'typeid:GUID'.
    m = re.match(r'^typeid:([0-9a-fA-F-]{36})$', type_str)
    if m:
        lines.append(f'{indent}<v8:TypeId>{m.group(1)}</v8:TypeId>')
        return
    # boolean
    if type_str == 'boolean':
        lines.append(f'{indent}<v8:Type>xs:boolean</v8:Type>')
        return

    # string or string(N) or string(N,fixed) (AllowedLength: Variable дефолт / Fixed)
    m = re.match(r'^string(\((\d+)(\s*,\s*(fixed|variable))?\))?$', type_str, re.IGNORECASE)
    if m:
        length = m.group(2) if m.group(2) else '0'
        al = 'Fixed' if (m.group(4) and m.group(4).lower() == 'fixed') else 'Variable'
        lines.append(f'{indent}<v8:Type>xs:string</v8:Type>')
        lines.append(f'{indent}<v8:StringQualifiers>')
        lines.append(f'{indent}\t<v8:Length>{length}</v8:Length>')
        lines.append(f'{indent}\t<v8:AllowedLength>{al}</v8:AllowedLength>')
        lines.append(f'{indent}</v8:StringQualifiers>')
        return

    # decimal(D,F) or decimal(D,F,nonneg)
    m = re.match(r'^decimal\((\d+),(\d+)(,nonneg)?\)$', type_str)
    if m:
        digits = m.group(1)
        fraction = m.group(2)
        sign = 'Nonnegative' if m.group(3) else 'Any'
        lines.append(f'{indent}<v8:Type>xs:decimal</v8:Type>')
        lines.append(f'{indent}<v8:NumberQualifiers>')
        lines.append(f'{indent}\t<v8:Digits>{digits}</v8:Digits>')
        lines.append(f'{indent}\t<v8:FractionDigits>{fraction}</v8:FractionDigits>')
        lines.append(f'{indent}\t<v8:AllowedSign>{sign}</v8:AllowedSign>')
        lines.append(f'{indent}</v8:NumberQualifiers>')
        return

    # date / dateTime / time
    m = re.match(r'^(date|dateTime|time)$', type_str)
    if m:
        fractions_map = {'date': 'Date', 'dateTime': 'DateTime', 'time': 'Time'}
        fractions = fractions_map[type_str]
        lines.append(f'{indent}<v8:Type>xs:dateTime</v8:Type>')
        lines.append(f'{indent}<v8:DateQualifiers>')
        lines.append(f'{indent}\t<v8:DateFractions>{fractions}</v8:DateFractions>')
        lines.append(f'{indent}</v8:DateQualifiers>')
        return

    # V8 types
    if type_str in V8_TYPES:
        lines.append(f'{indent}<v8:Type>{V8_TYPES[type_str]}</v8:Type>')
        return

    # UI types
    if type_str in UI_TYPES:
        lines.append(f'{indent}<v8:Type>{UI_TYPES[type_str]}</v8:Type>')
        return

    # DCS types
    if type_str.startswith('DataComposition'):
        if type_str in DCS_MAP:
            lines.append(f'{indent}<v8:Type>{DCS_MAP[type_str]}</v8:Type>')
            return

    # Голые конфигурационные типы (cfg: без .Имя): дин-список, набор констант, общий объект отчёта.
    # Корпус (acc+erp 8.3.24): DynamicList 5205, ConstantsSet 103, ReportObject 10.
    if type_str in ('DynamicList', 'ConstantsSet', 'ReportObject'):
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return

    # TypeSet (набор типов) → <v8:TypeSet>: определяемый тип / характеристика (именованные)
    # + «любая ссылка вида» (голый ref-вид без .Имя). Развязка с обычным типом — по наличию точки.
    if re.match(r'^(DefinedType|Characteristic)\.', type_str):
        lines.append(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return
    if re.match(r'^(AnyRef|AnyIBRef|CatalogRef|DocumentRef|EnumRef|ExchangePlanRef|TaskRef|BusinessProcessRef|ChartOfAccountsRef|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef)$', type_str):
        lines.append(f'{indent}<v8:TypeSet>cfg:{type_str}</v8:TypeSet>')
        return

    # cfg: references
    if CFG_REF_PATTERN.match(type_str):
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
        return

    # Спец-типы платформы с собственным namespace (объявляется ЛОКАЛЬНО на <v8:Type>).
    # Префикс d5p1 неоднозначен (5 разных URI), поэтому маппинг по полному значению типа.
    # К таким типам привязаны спец-поля: mxl→SpreadSheetDocumentField, fd→FormattedDocumentField,
    # d5p1:TextDocument→TextDocumentField, pdfdoc→PDF, pl→Planner, chart/geo/graphscheme/data-analysis.
    special_type_ns = {
        "mxl:SpreadsheetDocument": "http://v8.1c.ru/8.2/data/spreadsheet",
        "fd:FormattedDocument": "http://v8.1c.ru/8.2/data/formatted-document",
        "d5p1:TextDocument": "http://v8.1c.ru/8.1/data/txtedt",
        "d5p1:Chart": "http://v8.1c.ru/8.2/data/chart",
        "d5p1:GanttChart": "http://v8.1c.ru/8.2/data/chart",
        "d5p1:Dendrogram": "http://v8.1c.ru/8.2/data/chart",
        "d5p1:FlowchartContextType": "http://v8.1c.ru/8.2/data/graphscheme",
        "d5p1:DataAnalysisTimeIntervalUnitType": "http://v8.1c.ru/8.2/data/data-analysis",
        "d5p1:GeographicalSchema": "http://v8.1c.ru/8.2/data/geo",
        "pdfdoc:PDFDocument": "http://v8.1c.ru/8.3/data/pdf",
        "pl:Planner": "http://v8.1c.ru/8.3/data/planner",
    }
    if type_str in special_type_ns:
        pref = type_str.split(':', 1)[0]
        lines.append(f'{indent}<v8:Type xmlns:{pref}="{special_type_ns[type_str]}">{type_str}</v8:Type>')
        return

    # Fallback with validation
    if type_str in KNOWN_INVALID_TYPES:
        raise ValueError(f"Invalid form attribute type '{type_str}': {KNOWN_INVALID_TYPES[type_str]}")
    # Платформенный тип с префиксом (v8:/v8ui:/xs:/dcs*:) — verbatim (напр. v8:UUID, v8:StandardPeriod).
    if re.match(r'^(v8|v8ui|xs|ent|style|sys|web|win|dcs\w*):', type_str):
        lines.append(f'{indent}<v8:Type>{type_str}</v8:Type>')
    elif '.' in type_str:
        lines.append(f'{indent}<v8:Type>cfg:{type_str}</v8:Type>')
    else:
        print(f"WARNING: Unrecognized bare type '{type_str}' — will be emitted without namespace prefix", file=sys.stderr)
        lines.append(f'{indent}<v8:Type>{type_str}</v8:Type>')


def emit_type(lines, type_str, indent, tag="Type", tag_attrs=""):
    # tag/tag_attrs — обёртка (по умолчанию <Type>); для valueType ValueList вызывается с
    # tag="Settings", tag_attrs=' xsi:type="v8:TypeDescription"'.
    if not type_str:
        lines.append(f'{indent}<{tag}{tag_attrs}/>')
        return

    type_string = str(type_str)
    parts = [p.strip() for p in re.split(r'[|+]', type_string)]

    lines.append(f'{indent}<{tag}{tag_attrs}>')
    for part in parts:
        emit_single_type(lines, part, f'{indent}\t')
    lines.append(f'{indent}</{tag}>')


# --- Element emitters ---


def normalize_element_type_synonyms(el):
    # Silent synonyms: model often writes XML name or Russian (ПолеПереключателя/RadioButtonField → radio).
    # commandBar/autoCommandBar/КоманднаяПанель → тип-элемент ТОЛЬКО при строковом значении (имя).
    for src, dst in ELEMENT_TYPE_SYNONYMS.items():
        if src in el and dst not in el:
            if src in STR_ONLY_TYPE_SYNONYMS and not isinstance(el[src], str):
                continue
            el[dst] = el.pop(src)


def emit_element(lines, el, indent, in_cmd_bar=False):
    # Companion-панели (объект/массив-значение) → commandBar/contextMenu, до тип-синонимов.
    normalize_panel_synonyms(el)

    # Синонимы типа (XML-имя, русское имя) → канонический ключ DSL
    normalize_element_type_synonyms(el)

    # Синонимы ключей-свойств (русские имена 1С → канон. англ.). Case/space-insensitive.
    # Канон побеждает: если задан и русский, и англ. ключ — англ. остаётся, русский отбрасываем.
    for p_name in list(el.keys()):
        norm = p_name.replace(' ', '').lower()
        canon = PROP_SYNONYMS.get(norm)
        if canon and p_name != canon:
            val = el.pop(p_name)
            if canon not in el:
                el[canon] = val

    type_key = None
    for key in TYPE_KEYS:
        if el.get(key) is not None:
            type_key = key
            break

    if not type_key:
        print("WARNING: Unknown element type, skipping", file=sys.stderr)
        return

    # Validate known keys (внутренние маркеры на _ пропускаем). Оформление (цвета/шрифты/граница)
    # проверяем против самих структур appearance — канонические ключи + forgiving-синонимы, чтобы
    # allowlist не дрейфовал при добавлении новых.
    for p_name in el.keys():
        if p_name.startswith('_'):
            continue
        if p_name not in KNOWN_KEYS and p_name not in APPEARANCE_SPEC and p_name not in APPEARANCE_SYNONYMS \
                and p_name not in GENERIC_SCALAR_KEYS:
            print(f"WARNING: Element '{el.get(type_key, '')}': unknown key '{p_name}' -- ignored. Check SKILL.md for valid keys.", file=sys.stderr)

    name = get_element_name(el, type_key)
    _ensure_unique(name, _seen_element_names, 'element')
    eid = new_id()

    emitters = {
        'group': emit_group,
        'columnGroup': emit_column_group,
        'buttonGroup': emit_button_group,
        'input': emit_input,
        'check': emit_check,
        'radio': emit_radio_button_field,
        'label': emit_label,
        'labelField': emit_label_field,
        'table': emit_table,
        'pages': emit_pages,
        'page': emit_page,
        'button': emit_button,
        'picture': emit_picture_decoration,
        'picField': emit_picture_field,
        'calendar': emit_calendar,
        'cmdBar': emit_command_bar,
        'popup': emit_popup,
        'searchString':  lambda lines, el, name, eid, indent: emit_addition(lines, el, name, eid, 'searchString', indent),
        'viewStatus':    lambda lines, el, name, eid, indent: emit_addition(lines, el, name, eid, 'viewStatus', indent),
        'searchControl': lambda lines, el, name, eid, indent: emit_addition(lines, el, name, eid, 'searchControl', indent),
        'spreadsheet':   lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'SpreadSheetDocumentField', 'spreadsheet'),
        'html':          lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'HTMLDocumentField', 'html'),
        'textDoc':       lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'TextDocumentField', 'textDoc'),
        'formattedDoc':  lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'FormattedDocumentField', 'formattedDoc'),
        'progressBar':   lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'ProgressBarField', 'progressBar'),
        'trackBar':      lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'TrackBarField', 'trackBar'),
        'chart':           lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'ChartField', 'chart'),
        'graphicalSchema': lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'GraphicalSchemaField', 'graphicalSchema'),
        'planner':         lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'PlannerField', 'planner'),
        'periodField':     lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'PeriodField', 'periodField'),
        'dendrogram':      lambda lines, el, name, eid, indent: emit_simple_field(lines, el, name, eid, indent, 'DendrogramField', 'dendrogram'),
        'ganttChart':      emit_gantt_chart,
    }

    emitter = emitters.get(type_key)
    if emitter:
        if type_key == 'button':
            emitter(lines, el, name, eid, indent, in_cmd_bar=in_cmd_bar)
        else:
            emitter(lines, el, name, eid, indent)


def _warn_unrecognized(key, raw, valid, owner):
    # drop-on-miss enum: значение не распознано → тег не эмитится. Громко, чтобы автор увидел потерю.
    print(f"[WARN] Unrecognized {key} '{raw}' on '{owner}'. Valid values: {', '.join(valid)}. Value ignored.")


def emit_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<UsualGroup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    # Group orientation
    # Group orientation (направление). Legacy: group:'collapsible' = Vertical + behavior collapsible.
    group_val = str(el.get('group', '')).lower()
    orientation_map = {
        'horizontal': 'Horizontal',
        'vertical': 'Vertical',
        'alwayshorizontal': 'AlwaysHorizontal',
        'alwaysvertical': 'AlwaysVertical',
        'horizontalifpossible': 'HorizontalIfPossible',
        'collapsible': 'Vertical',
    }
    orientation = orientation_map.get(group_val)
    if orientation:
        lines.append(f'{inner}<Group>{orientation}</Group>')
    elif group_val:
        _warn_unrecognized('group orientation', el.get('group'), ('vertical', 'horizontalIfPossible', 'alwaysHorizontal'), name)

    # Behavior: ключ behavior (usual/collapsible/popup) → <Behavior>; отсутствие = Авто (не эмитим).
    behavior_val = str(el['behavior']).lower() if el.get('behavior') else ('collapsible' if group_val == 'collapsible' else None)
    bmap = {'usual': 'Usual', 'collapsible': 'Collapsible', 'popup': 'PopUp'}
    if behavior_val and behavior_val in bmap:
        lines.append(f'{inner}<Behavior>{bmap[behavior_val]}</Behavior>')
    elif el.get('behavior') and behavior_val not in bmap:
        _warn_unrecognized('behavior', el.get('behavior'), ('collapsible', 'popup'), name)
    # Collapsed — у Collapsible и PopUp (не привязано к одному behavior)
    if el.get('collapsed') is True:
        lines.append(f'{inner}<Collapsed>true</Collapsed>')

    # Representation
    if el.get('representation'):
        repr_map = {
            'none': 'None',
            'normal': 'NormalSeparation',
            'weak': 'WeakSeparation',
            'strong': 'StrongSeparation',
        }
        repr_val = repr_map.get(str(el['representation']), str(el['representation']))
        lines.append(f'{inner}<Representation>{repr_val}</Representation>')

    # Использование текущей строки группы (после Representation, порядок XSD)
    if el.get('currentRowUse'):
        lines.append(f'{inner}<CurrentRowUse>{el["currentRowUse"]}</CurrentRowUse>')

    # ShowTitle
    if el.get('showTitle') is not None:
        lines.append(f'{inner}<ShowTitle>{"true" if el["showTitle"] else "false"}</ShowTitle>')
    # Заголовок свёрнутого представления (collapsible/popup) — мультиязычный текст
    if el.get('collapsedTitle'):
        emit_mltext(lines, inner, 'CollapsedRepresentationTitle', el['collapsedTitle'])

    # United
    if el.get('united') is False:
        lines.append(f'{inner}<United>false</United>')

    # Формат значения пути к данным заголовка (<Format>; парный к titleDataPath группы)
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # Оформление (цвета/шрифты/граница) — перед компаньоном
    emit_appearance(lines, el, inner, 'field')

    # Companion: ExtendedTooltip
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</UsualGroup>')


def emit_column_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<ColumnGroup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    group_val = str(el.get('columnGroup', '')).lower()
    orientation_map = {
        'horizontal': 'Horizontal',
        'vertical': 'Vertical',
        'incell': 'InCell',
    }
    orientation = orientation_map.get(group_val)
    if orientation:
        lines.append(f'{inner}<Group>{orientation}</Group>')
    elif group_val:
        _warn_unrecognized('columnGroup orientation', el.get('columnGroup'), ('vertical', 'horizontal', 'inCell'), name)

    if el.get('showTitle') is not None:
        lines.append(f'{inner}<ShowTitle>{"true" if el["showTitle"] else "false"}</ShowTitle>')
    # showInHeader эмитится общим emit_common_element_props (через emit_layout)

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # Картинка заголовка колонки-группы (после ShowInHeader/Layout, перед оформлением — порядок XSD)
    emit_column_pics(lines, el, inner)

    # Оформление (цвета/шрифты/граница) — перед компаньоном
    emit_appearance(lines, el, inner, 'field')

    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</ColumnGroup>')


def emit_input(lines, el, name, eid, indent):
    lines.append(f'{indent}<InputField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        loc_map = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom'}
        loc = loc_map.get(str(el['titleLocation']), str(el['titleLocation']))
        lines.append(f'{inner}<TitleLocation>{loc}</TitleLocation>')

    if el.get('multiLine') is not None:
        lines.append(f'{inner}<MultiLine>{"true" if el["multiLine"] else "false"}</MultiLine>')
    if el.get('passwordMode') is not None:
        lines.append(f'{inner}<PasswordMode>{"true" if el["passwordMode"] else "false"}</PasswordMode>')
    # ChoiceButton — захват «как есть» (платформа эмитит явное значение; ref-поля выводят сама,
    # декомпилятор фиксирует факт. значение). Нет ключа → не эмитим (не додумываем по событию).
    if el.get('choiceButton') is not None:
        lines.append(f'{inner}<ChoiceButton>{"true" if el["choiceButton"] else "false"}</ChoiceButton>')
    # Кнопки поля ввода — захват «как есть» (платформа эмитит явное значение, в т.ч. false)
    if el.get('clearButton') is not None:
        lines.append(f'{inner}<ClearButton>{"true" if el["clearButton"] else "false"}</ClearButton>')
    if el.get('spinButton') is not None:
        lines.append(f'{inner}<SpinButton>{"true" if el["spinButton"] else "false"}</SpinButton>')
    if el.get('dropListButton') is not None:
        lines.append(f'{inner}<DropListButton>{"true" if el["dropListButton"] else "false"}</DropListButton>')
    if el.get('choiceListButton') is not None:
        lines.append(f'{inner}<ChoiceListButton>{"true" if el["choiceListButton"] else "false"}</ChoiceListButton>')
    if el.get('markIncomplete') is not None:
        lines.append(f'{inner}<AutoMarkIncomplete>{"true" if el["markIncomplete"] else "false"}</AutoMarkIncomplete>')
    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_column_pics(lines, el, inner)
    if el.get('textEdit') is False:
        lines.append(f'{inner}<TextEdit>false</TextEdit>')
    # InputField-специфичные скаляры (захват «как есть»: платформа эмитит явное не-дефолтное значение)
    for key, tag in (('wrap', 'Wrap'), ('openButton', 'OpenButton'), ('listChoiceMode', 'ListChoiceMode'),
                     ('extendedEditMultipleValues', 'ExtendedEditMultipleValues'), ('chooseType', 'ChooseType'),
                     ('quickChoice', 'QuickChoice'), ('autoChoiceIncomplete', 'AutoChoiceIncomplete')):
        if el.get(key) is not None:
            lines.append(f'{inner}<{tag}>{"true" if el[key] else "false"}</{tag}>')
    # Ограничение доступных типов (поле на составном типе): домен типов + явный набор.
    # availableTypes — формат типа реквизита (§type); emit_type сам разбирает мультитип "a | b".
    if el.get('typeDomainEnabled') is not None:
        lines.append(f'{inner}<TypeDomainEnabled>{"true" if el["typeDomainEnabled"] else "false"}</TypeDomainEnabled>')
    if el.get('availableTypes'):
        emit_type(lines, el['availableTypes'], inner, tag='AvailableTypes')
    # InputField-специфичные value-скаляры
    for key, tag in (('choiceForm', 'ChoiceForm'), ('choiceHistoryOnInput', 'ChoiceHistoryOnInput'),
                     ('choiceFoldersAndItems', 'ChoiceFoldersAndItems'), ('footerDataPath', 'FooterDataPath')):
        if el.get(key):
            lines.append(f'{inner}<{tag}>{esc_xml_text(str(el[key]))}</{tag}>')
    # MinValue/MaxValue — типизированное. JSON-число → xs:decimal, строка → xs:string (тип сохранён декомпилятором).
    for key, tag in (('minValue', 'MinValue'), ('maxValue', 'MaxValue')):
        if el.get(key) is not None:
            mvt = 'xs:string' if isinstance(el[key], str) else 'xs:decimal'
            lines.append(f'{inner}<{tag} xsi:type="{mvt}">{esc_xml_text(str(el[key]))}</{tag}>')
    if el.get('choiceButtonRepresentation'):
        lines.append(f'{inner}<ChoiceButtonRepresentation>{el["choiceButtonRepresentation"]}</ChoiceButtonRepresentation>')
    emit_picture_ref(lines, el.get('choiceButtonPicture'), 'ChoiceButtonPicture', inner)
    emit_layout(lines, el, inner, multi_line_default=(el.get('multiLine') is True))

    if el.get('inputHint'):
        emit_mltext(lines, inner, 'InputHint', el['inputHint'])
    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # Формат / формат редактирования (LocalStringType — строка или {ru,en})
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    emit_choice_list(lines, el, inner)

    # Связи по типу / связи параметров выбора / параметры выбора
    emit_type_link(lines, el, inner)
    emit_choice_parameter_links(lines, el, inner)
    emit_choice_parameters(lines, el, inner)

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'input')

    lines.append(f'{indent}</InputField>')


def emit_check(lines, el, name, eid, indent):
    lines.append(f'{indent}<CheckBoxField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_column_pics(lines, el, inner)
    # CheckBoxType: нет ключа → умный дефолт Auto; "" → подавить; значение → маппинг
    _cbt_map = {'auto': 'Auto', 'checkbox': 'CheckBox', 'switcher': 'Switcher', 'tumbler': 'Tumbler'}
    if 'checkBoxType' in el:
        if el.get('checkBoxType'):
            lines.append(f'{inner}<CheckBoxType>{_cbt_map.get(str(el["checkBoxType"]).lower(), el["checkBoxType"])}</CheckBoxType>')
    else:
        lines.append(f'{inner}<CheckBoxType>Auto</CheckBoxType>')

    emit_title_location(lines, el, inner, 'Right')

    emit_layout(lines, el, inner)

    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])
    # FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
    if el.get('footerDataPath'):
        lines.append(f'{inner}<FooterDataPath>{esc_xml_text(str(el["footerDataPath"]))}</FooterDataPath>')
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # Формат / формат редактирования (LocalStringType — строка или {ru,en})
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'check')

    lines.append(f'{indent}</CheckBoxField>')


def emit_radio_button_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<RadioButtonField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_title_location(lines, el, inner, 'None')

    rbt = normalize_radio_button_type(el.get('radioButtonType'))
    lines.append(f'{inner}<RadioButtonType>{rbt}</RadioButtonType>')

    if el.get('columnsCount') is not None:
        lines.append(f'{inner}<ColumnsCount>{el["columnsCount"]}</ColumnsCount>')

    emit_choice_list(lines, el, inner)

    emit_layout(lines, el, inner)

    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    emit_companion_panel(lines, 'ContextMenu', f'{name}КонтекстноеМеню', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'radio')

    lines.append(f'{indent}</RadioButtonField>')


# Заголовок декорации (Label/Picture): formatted-aware <Title> через единую ML-text форму
# (reuse resolve_ml_formatted, как у extendedTooltip). Sibling-ключ formatted — back-compat override.


def emit_decoration_title(lines, el, name, indent, auto=False):
    has_key = 'title' in el
    title_val = el['title'] if has_key else (title_from_name(name) if (auto and name) else None)
    if title_val:
        text, fmt = resolve_ml_formatted(title_val)
        if 'formatted' in el:
            fmt = bool(el['formatted'])
        lines.append(f'{indent}<Title formatted="{"true" if fmt else "false"}">')
        emit_ml_items(lines, f'{indent}\t', text)
        lines.append(f'{indent}</Title>')
    if el.get('tooltip'):
        emit_mltext(lines, indent, 'ToolTip', el['tooltip'])
    if el.get('tooltipRepresentation'):
        lines.append(f'{indent}<ToolTipRepresentation>{el["tooltipRepresentation"]}</ToolTipRepresentation>')


def emit_label(lines, el, name, eid, indent):
    lines.append(f'{indent}<LabelDecoration name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    # Порядок как у платформы: own-content (флаги/hyperlink/layout/оформление) ПЕРЕД Title
    # (корпус layout-first 16970 vs 44 — заодно убирает шум атрибуции харнесса на многострочном Title).
    emit_common_flags(lines, el, inner)
    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
    emit_layout(lines, el, inner)
    emit_appearance(lines, el, inner, 'decoration')

    emit_decoration_title(lines, el, name, inner, auto=True)

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'label')

    lines.append(f'{indent}</LabelDecoration>')


def emit_label_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<LabelField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    # FooterDataPath — путь данных подвала колонки (общий cell-prop, как у input); после EditMode
    if el.get('footerDataPath'):
        lines.append(f'{inner}<FooterDataPath>{esc_xml_text(str(el["footerDataPath"]))}</FooterDataPath>')
    # PasswordMode на LabelField — платформа эмитит явный false (редко); факт. значение
    if el.get('passwordMode') is not None:
        lines.append(f'{inner}<PasswordMode>{"true" if el["passwordMode"] else "false"}</PasswordMode>')
    emit_column_pics(lines, el, inner)
    # ВНИМАНИЕ: у LabelField платформенный тег <Hiperlink> (опечатка 1С), не <Hyperlink>.
    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hiperlink>true</Hiperlink>')
    emit_layout(lines, el, inner)

    if el.get('warningOnEdit') is not None:
        emit_mltext(lines, inner, 'WarningOnEdit', el['warningOnEdit'])
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # Формат / формат редактирования (LocalStringType — строка или {ru,en})
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])

    # Оформление (цвета/шрифты/граница + header/footer) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'labelField')

    lines.append(f'{indent}</LabelField>')


# Блок свойств таблицы, привязанной к динамическому списку (Group A defaults + B/C).


def emit_dynlist_table_block(lines, el, indent):
    # (useAlternationRowColor — общее свойство таблицы, эмитится в emit_table)
    # Group A (гарант. блок): дефолт + override
    ar = 'true' if el.get('autoRefresh') is True else 'false'
    lines.append(f'{indent}<AutoRefresh>{ar}</AutoRefresh>')
    arp = el['autoRefreshPeriod'] if el.get('autoRefreshPeriod') is not None else 60
    lines.append(f'{indent}<AutoRefreshPeriod>{arp}</AutoRefreshPeriod>')
    lines.append(f'{indent}<Period>')
    lines.append(f'{indent}\t<v8:variant xsi:type="v8:StandardPeriodVariant">Custom</v8:variant>')
    lines.append(f'{indent}\t<v8:startDate>0001-01-01T00:00:00</v8:startDate>')
    lines.append(f'{indent}\t<v8:endDate>0001-01-01T00:00:00</v8:endDate>')
    lines.append(f'{indent}</Period>')
    cfi = el.get('choiceFoldersAndItems') or 'Items'
    lines.append(f'{indent}<ChoiceFoldersAndItems>{cfi}</ChoiceFoldersAndItems>')
    rcr = 'true' if el.get('restoreCurrentRow') is True else 'false'
    lines.append(f'{indent}<RestoreCurrentRow>{rcr}</RestoreCurrentRow>')
    lines.append(f'{indent}<TopLevelParent xsi:nil="true"/>')
    sr = 'false' if el.get('showRoot') is False else 'true'
    lines.append(f'{indent}<ShowRoot>{sr}</ShowRoot>')
    arc = 'true' if el.get('allowRootChoice') is True else 'false'
    lines.append(f'{indent}<AllowRootChoice>{arc}</AllowRootChoice>')
    uodc = el.get('updateOnDataChange') or 'Auto'
    lines.append(f'{indent}<UpdateOnDataChange>{uodc}</UpdateOnDataChange>')
    if el.get('userSettingsGroup'):
        lines.append(f'{indent}<UserSettingsGroup>{el["userSettingsGroup"]}</UserSettingsGroup>')
    agcru = 'false' if el.get('allowGettingCurrentRowURL') is False else 'true'
    lines.append(f'{indent}<AllowGettingCurrentRowURL>{agcru}</AllowGettingCurrentRowURL>')


def emit_table(lines, el, name, eid, indent):
    _current_table_name['name'] = name   # дефолт source для кастомных дополнений в commandBar
    lines.append(f'{indent}<Table name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    # ChangeRowSet/Order — явное значение (в т.ч. false: платформа пишет его на ValueTable)
    if 'changeRowSet' in el and el['changeRowSet'] is not None:
        lines.append(f'{inner}<ChangeRowSet>{"true" if el["changeRowSet"] is True else "false"}</ChangeRowSet>')
    if 'changeRowOrder' in el and el['changeRowOrder'] is not None:
        lines.append(f'{inner}<ChangeRowOrder>{"true" if el["changeRowOrder"] is True else "false"}</ChangeRowOrder>')
    if el.get('autoInsertNewRow') is True:
        lines.append(f'{inner}<AutoInsertNewRow>true</AutoInsertNewRow>')
    # RowFilter — nil-плейсхолдер (ключ присутствует → эмитим)
    if 'rowFilter' in el:
        lines.append(f'{inner}<RowFilter xsi:nil="true"/>')
    # Высота в строках (<HeightInTableRows>) — отдельное свойство от <Height> (высота элемента,
    # эмитится generic-ом emit_layout ниже). Таблица может нести оба (237 в корпусе).
    if el.get('heightInTableRows'):
        lines.append(f'{inner}<HeightInTableRows>{el["heightInTableRows"]}</HeightInTableRows>')
    if el.get('header') is False:
        lines.append(f'{inner}<Header>false</Header>')
    if el.get('footer') is True:
        lines.append(f'{inner}<Footer>true</Footer>')

    if el.get('commandBarLocation'):
        lines.append(f'{inner}<CommandBarLocation>{el["commandBarLocation"]}</CommandBarLocation>')
    if el.get('searchStringLocation'):
        lines.append(f'{inner}<SearchStringLocation>{el["searchStringLocation"]}</SearchStringLocation>')

    if el.get('choiceMode') is True:
        lines.append(f'{inner}<ChoiceMode>true</ChoiceMode>')
    # Скаляры таблицы (захват «как есть»). Autofill — СВОЁ свойство таблицы (≠ AutoCommandBar autofill = tableAutofill).
    if el.get('autofill') is not None:
        lines.append(f'{inner}<Autofill>{"true" if el["autofill"] else "false"}</Autofill>')
    if el.get('multipleChoice') is True:
        lines.append(f'{inner}<MultipleChoice>true</MultipleChoice>')
    if el.get('searchOnInput'):
        lines.append(f'{inner}<SearchOnInput>{el["searchOnInput"]}</SearchOnInput>')
    if el.get('markIncomplete') is not None:
        lines.append(f'{inner}<AutoMarkIncomplete>{"true" if el["markIncomplete"] else "false"}</AutoMarkIncomplete>')
    # Высота шапки/подвала в строках (pass-through; 1С толерантна к порядку детей Table)
    if el.get('headerHeight') is not None:
        lines.append(f'{inner}<HeaderHeight>{el["headerHeight"]}</HeaderHeight>')
    if el.get('footerHeight') is not None:
        lines.append(f'{inner}<FooterHeight>{el["footerHeight"]}</FooterHeight>')
    if el.get('useAlternationRowColor') is True:
        lines.append(f'{inner}<UseAlternationRowColor>true</UseAlternationRowColor>')
    if el.get('selectionMode'):
        lines.append(f'{inner}<SelectionMode>{el["selectionMode"]}</SelectionMode>')
    if el.get('rowSelectionMode'):
        lines.append(f'{inner}<RowSelectionMode>{el["rowSelectionMode"]}</RowSelectionMode>')
    if el.get('verticalLines') is False:
        lines.append(f'{inner}<VerticalLines>false</VerticalLines>')
    if el.get('horizontalLines') is False:
        lines.append(f'{inner}<HorizontalLines>false</HorizontalLines>')
    if el.get('initialTreeView'):
        lines.append(f'{inner}<InitialTreeView>{el["initialTreeView"]}</InitialTreeView>')
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')
    if el.get('rowPictureDataPath'):
        lines.append(f'{inner}<RowPictureDataPath>{el["rowPictureDataPath"]}</RowPictureDataPath>')
    # RowsPicture — та же конвенция, что ValuesPicture (дефолт LoadTransparent=false; abs/TransparentPixel)
    emit_picture_ref(lines, el.get('rowsPicture'), 'RowsPicture', inner)
    # Использование текущей строки таблицы (pass-through; в корпусе соседствует с блоком дин-списка)
    if el.get('currentRowUse'):
        lines.append(f'{inner}<CurrentRowUse>{el["currentRowUse"]}</CurrentRowUse>')
    # Запрос обновления дин-списка (pass-through; в корпусе всегда PullFromTop)
    if el.get('refreshRequest'):
        lines.append(f'{inner}<RefreshRequest>{el["refreshRequest"]}</RefreshRequest>')
    # Блок свойств дин-список-таблицы (помечена эвристикой)
    if el.get('_dynList'):
        emit_dynlist_table_block(lines, el, inner)
    if el.get('viewStatusLocation'):
        lines.append(f'{inner}<ViewStatusLocation>{el["viewStatusLocation"]}</ViewStatusLocation>')
    if el.get('searchControlLocation'):
        lines.append(f'{inner}<SearchControlLocation>{el["searchControlLocation"]}</SearchControlLocation>')
    emit_layout(lines, el, inner)

    # CommandSet таблицы эмитится через emit_layout (общий механизм поля)

    # Оформление (цвета/граница таблицы) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    # AutoCommandBar — with optional Autofill control
    if el.get('commandBar') is not None:
        emit_companion_panel(lines, 'AutoCommandBar', f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c', inner, el.get('commandBar'))
    elif el.get('tableAutofill') is not None:
        acb_id = new_id()
        acb_name = f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c'
        af_val = 'true' if el['tableAutofill'] else 'false'
        lines.append(f'{inner}<AutoCommandBar name="{acb_name}" id="{acb_id}">')
        lines.append(f'{inner}\t<Autofill>{af_val}</Autofill>')
        lines.append(f'{inner}</AutoCommandBar>')
    else:
        emit_companion(lines, 'AutoCommandBar', f'{name}\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c', inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))
    adds = el.get('additions')
    emit_table_addition(lines, 'searchString',  name, inner, get_addition_override(adds, 'searchString'))
    emit_table_addition(lines, 'viewStatus',    name, inner, get_addition_override(adds, 'viewStatus'))
    emit_table_addition(lines, 'searchControl', name, inner, get_addition_override(adds, 'searchControl'))

    # Columns
    if el.get('columns') and len(el['columns']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for col in el['columns']:
            emit_element(lines, col, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    emit_events(lines, el, name, inner, 'table')

    lines.append(f'{indent}</Table>')


def emit_pages(lines, el, name, eid, indent):
    lines.append(f'{indent}<Pages name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    if el.get('pagesRepresentation'):
        lines.append(f'{inner}<PagesRepresentation>{el["pagesRepresentation"]}</PagesRepresentation>')
    # \u0418\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u043d\u0438\u0435 \u0442\u0435\u043a\u0443\u0449\u0435\u0439 \u0441\u0442\u0440\u043e\u043a\u0438 (\u043f\u043e\u0441\u043b\u0435 PagesRepresentation, \u043f\u043e\u0440\u044f\u0434\u043e\u043a XSD)
    if el.get('currentRowUse'):
        lines.append(f'{inner}<CurrentRowUse>{el["currentRowUse"]}</CurrentRowUse>')

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # \u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u0435 (\u0446\u0432\u0435\u0442\u0430/\u0448\u0440\u0438\u0444\u0442\u044b/\u0433\u0440\u0430\u043d\u0438\u0446\u0430) \u0437\u0430\u0433\u043e\u043b\u043e\u0432\u043a\u0430 \u0433\u0440\u0443\u043f\u043f\u044b \u0441\u0442\u0440\u0430\u043d\u0438\u0446 \u2014 TitleFont/TitleTextColor/\u2026 (\u043a\u0430\u043a \u0443 Page)
    emit_appearance(lines, el, inner, 'field')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'pages')

    # Children (pages)
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Pages>')


def emit_page(lines, el, name, eid, indent):
    lines.append(f'{indent}<Page name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner, auto=True)
    emit_common_flags(lines, el, inner)

    # Картинка страницы (иконка вкладки): после Title/флагов, перед Group (порядок XSD).
    # Конвенция как у ValuesPicture (дефолт LoadTransparent=false): скаляр-Ref/'abs:X' или объект.
    emit_picture_ref(lines, el.get('picture'), 'Picture', inner)

    if el.get('group'):
        orientation_map = {
            'horizontal': 'Horizontal',
            'vertical': 'Vertical',
            'alwayshorizontal': 'AlwaysHorizontal',
            'alwaysvertical': 'AlwaysVertical',
            'horizontalifpossible': 'HorizontalIfPossible',
        }
        orientation = orientation_map.get(str(el['group']).lower())
        if orientation:
            lines.append(f'{inner}<Group>{orientation}</Group>')
        else:
            _warn_unrecognized('page group orientation', el['group'], ('vertical', 'horizontalIfPossible', 'alwaysHorizontal'), name)
    if el.get('showTitle') is not None:
        lines.append(f'{inner}<ShowTitle>{"true" if el["showTitle"] else "false"}</ShowTitle>')
    # Формат значения пути к данным заголовка (<Format>; парный к titleDataPath страницы)
    if el.get('format'):
        emit_mltext(lines, inner, 'Format', el['format'])
    if el.get('editFormat'):
        emit_mltext(lines, inner, 'EditFormat', el['editFormat'])
    emit_layout(lines, el, inner)

    # \u041e\u0444\u043e\u0440\u043c\u043b\u0435\u043d\u0438\u0435 \u0441\u0442\u0440\u0430\u043d\u0438\u0446\u044b (BackColor / TitleTextColor / TitleFont) \u2014 \u043f\u043e\u0441\u043b\u0435 ShowTitle, \u043f\u0435\u0440\u0435\u0434 \u043a\u043e\u043c\u043f\u0430\u043d\u044c\u043e\u043d\u043e\u043c
    emit_appearance(lines, el, inner, 'field')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t')
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Page>')


def emit_button(lines, el, name, eid, indent, in_cmd_bar=False):
    lines.append(f'{indent}<Button name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'
    # (общие свойства — через emit_layout ниже; отдельный вызов был бы двойной эмиссией)

    # Type — context-aware. Inside command bars (cmdBar/autoCmdBar/popup) only
    # CommandBarButton/CommandBarHyperlink are valid; UsualButton/Hyperlink would be ignored.
    # Forgiving resolver: any "ordinary button" hint resolves to UsualButton/CommandBarButton,
    # any "hyperlink" hint resolves to Hyperlink/CommandBarHyperlink — depending on context.
    btn_type = None
    if el.get('type'):
        raw = str(el['type'])
        if in_cmd_bar:
            cmd_bar_map = {
                'usual': 'CommandBarButton',
                'UsualButton': 'CommandBarButton',
                'commandBar': 'CommandBarButton',
                'CommandBarButton': 'CommandBarButton',
                'hyperlink': 'CommandBarHyperlink',
                'Hyperlink': 'CommandBarHyperlink',
                'CommandBarHyperlink': 'CommandBarHyperlink',
            }
            btn_type = cmd_bar_map.get(raw, raw)
        else:
            normal_map = {
                'usual': 'UsualButton',
                'UsualButton': 'UsualButton',
                'commandBar': 'UsualButton',
                'CommandBarButton': 'UsualButton',
                'hyperlink': 'Hyperlink',
                'Hyperlink': 'Hyperlink',
                'CommandBarHyperlink': 'Hyperlink',
            }
            btn_type = normal_map.get(raw, raw)
    elif in_cmd_bar:
        btn_type = 'CommandBarButton'
    if btn_type:
        lines.append(f'{inner}<Type>{btn_type}</Type>')

    # CommandName
    if el.get('command'):
        lines.append(f'{inner}<CommandName>Form.Command.{el["command"]}</CommandName>')
    # commandName — глобальная команда «как есть» (CommonCommand.X, Catalog.X.Command.Y …), без обёртки Form.
    if el.get('commandName') and not el.get('command'):
        lines.append(f'{inner}<CommandName>{el["commandName"]}</CommandName>')
    if el.get('stdCommand'):
        sc = str(el['stdCommand'])
        m = re.match(r'^(.+)\.(.+)$', sc)
        if m:
            lines.append(f'{inner}<CommandName>Form.Item.{m.group(1)}.StandardCommand.{m.group(2)}</CommandName>')
        else:
            lines.append(f'{inner}<CommandName>Form.StandardCommand.{sc}</CommandName>')
    # Parameter команды (после CommandName): строка → xr:MDObjectRef (объект метаданных);
    # объект {type} → v8:TypeDescription (грамматика типа). Forgiving-синоним 'параметр'.
    btn_param = el.get('parameter')
    if btn_param is None:
        btn_param = el.get('параметр')
    if btn_param is not None:
        if isinstance(btn_param, dict) and btn_param.get('type'):
            emit_type(lines, str(btn_param['type']), inner, tag='Parameter', tag_attrs=' xsi:type="v8:TypeDescription"')
        else:
            lines.append(f'{inner}<Parameter xsi:type="xr:MDObjectRef">{esc_xml_text(str(btn_param))}</Parameter>')
    # DataPath — привязка команды кнопки к контексту (Объект.Ref, Items.X.CurrentData.Поле)
    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not (el.get('command') or el.get('commandName') or el.get('stdCommand')))
    emit_common_flags(lines, el, inner)

    if el.get('defaultButton') is True:
        lines.append(f'{inner}<DefaultButton>true</DefaultButton>')
    # Check (пометка toggle-кнопки командной панели) — платформа эмитит только true.
    # Ключ 'checked' (не 'check': 'check' — тип-ключ CheckBoxField, был бы конфликт диспетчера типов)
    if el.get('checked') is True:
        lines.append(f'{inner}<Check>true</Check>')

    # Picture
    emit_command_picture(lines, el.get('picture'), el.get('loadTransparent'), inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')

    if el.get('locationInCommandBar'):
        lines.append(f'{inner}<LocationInCommandBar>{el["locationInCommandBar"]}</LocationInCommandBar>')
    emit_layout(lines, el, inner)

    # Оформление (цвета/шрифт/граница) — перед компаньоном (профиль кнопки)
    emit_appearance(lines, el, inner, 'button')

    # Companion
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'button')

    lines.append(f'{indent}</Button>')


def emit_picture_decoration(lines, el, name, eid, indent):
    lines.append(f'{indent}<PictureDecoration name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_decoration_title(lines, el, name, inner)
    # Текст при невыбранной картинке (NonselectedPictureText) — после Title (порядок корпуса)
    if el.get('nonselectedPictureText') is not None:
        emit_mltext(lines, inner, 'NonselectedPictureText', el['nonselectedPictureText'])
    emit_common_flags(lines, el, inner)

    # Источник картинки — ТОЛЬКО src (ключ 'picture' = тип/имя элемента, не источник).
    # Префикс "abs:" → встроенная картинка <xr:Abs>; иначе именованная/стилевая <xr:Ref>.
    if el.get('src'):
        src_str = str(el['src'])
        lt = 'true' if el.get('loadTransparent') is True else 'false'
        lines.append(f'{inner}<Picture>')
        if src_str.startswith('abs:'):
            lines.append(f'{inner}\t<xr:Abs>{esc_xml_text(src_str[4:])}</xr:Abs>')
        else:
            lines.append(f'{inner}\t<xr:Ref>{esc_xml_text(src_str)}</xr:Ref>')
        lines.append(f'{inner}\t<xr:LoadTransparent>{lt}</xr:LoadTransparent>')
        tpx = el.get('transparentPixel')
        if tpx:
            lines.append(f'{inner}\t<xr:TransparentPixel x="{tpx.get("x")}" y="{tpx.get("y")}"/>')
        lines.append(f'{inner}</Picture>')

    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')
    emit_layout(lines, el, inner)
    # EnableDrag — фактическое значение (декорация-картинка перетаскиваема; декомпилятор ловит generic-ом)
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')

    # Оформление (цвета/шрифт/граница) — профиль декорации (1С толерантна к порядку appearance)
    emit_appearance(lines, el, inner, 'decoration')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'picture')

    lines.append(f'{indent}</PictureDecoration>')


def emit_picture_field(lines, el, name, eid, indent):
    lines.append(f'{indent}<PictureField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner)
    emit_common_flags(lines, el, inner)

    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')
    emit_column_pics(lines, el, inner)
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    if el.get('hyperlink') is True:
        lines.append(f'{inner}<Hyperlink>true</Hyperlink>')

    emit_layout(lines, el, inner)
    # EnableDrag — фактическое значение (поле картинки перетаскиваемо; декомпилятор ловит generic-ом)
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')

    # FooterDataPath / FooterText — общие cell-свойства колонки (как у input/labelField)
    if el.get('footerDataPath'):
        lines.append(f'{inner}<FooterDataPath>{esc_xml_text(str(el["footerDataPath"]))}</FooterDataPath>')
    if el.get('footerText') is not None:
        emit_mltext(lines, inner, 'FooterText', el['footerText'])

    # ValuesPicture — picture (collection) used to render the field's value.
    # Required for a Boolean-bound PictureField to actually show an icon.
    # Скаляр (Ref) или объект {src, loadTransparent}; LoadTransparent эмитится всегда.
    emit_picture_ref(lines, el.get('valuesPicture'), 'ValuesPicture', inner)
    if el.get('nonselectedPictureText') is not None:
        emit_mltext(lines, inner, 'NonselectedPictureText', el['nonselectedPictureText'])

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'picField')

    lines.append(f'{indent}</PictureField>')


def emit_simple_field(lines, el, name, eid, indent, xml_tag, type_key):
    # Спец-поля "документ/датчик" (SpreadSheet/HTML/Text/Formatted/ProgressBar/TrackBar):
    # единый скелет поля. Типоспец. enum/bool скаляры — через generic (emit_layout);
    # числовые скаляры датчиков (min/max/шаги) — без xsi:type; enableDrag — фактическое значение.
    lines.append(f'{indent}<{xml_tag} name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')
    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    if el.get('editMode'):
        lines.append(f'{inner}<EditMode>{el["editMode"]}</EditMode>')

    emit_layout(lines, el, inner)

    # EnableDrag — фактическое значение (SpreadSheet; платформа эмитит явный false). enableStartDrag — через emit_layout.
    if el.get('enableDrag') is not None:
        lines.append(f'{inner}<EnableDrag>{"true" if el["enableDrag"] else "false"}</EnableDrag>')

    # Датчики (ProgressBar/TrackBar) — числовые скаляры (без xsi:type)
    for key, tag in (('minValue', 'MinValue'), ('maxValue', 'MaxValue'), ('largeStep', 'LargeStep'), ('markingStep', 'MarkingStep'), ('step', 'Step')):
        if el.get(key) is not None:
            lines.append(f'{inner}<{tag}>{el[key]}</{tag}>')

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}КонтекстноеМеню', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, type_key)

    lines.append(f'{indent}</{xml_tag}>')


def emit_gantt_chart(lines, el, name, eid, indent):
    # GanttChartField — скелет поля + вложенная <Table> (полноценная таблица, через emit_element).
    lines.append(f'{indent}<GanttChartField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'
    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')
    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)
    if el.get('titleLocation'):
        lines.append(f'{inner}<TitleLocation>{map_title_loc(el["titleLocation"])}</TitleLocation>')
    emit_layout(lines, el, inner)
    emit_appearance(lines, el, inner, 'field')
    emit_companion_panel(lines, 'ContextMenu', f'{name}КонтекстноеМеню', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))
    # Вложенная таблица диаграммы Ганта (стандартный Table — переиспользуем emit_element)
    if el.get('ganttTable'):
        emit_element(lines, el['ganttTable'], inner)
    emit_events(lines, el, name, inner, 'ganttChart')
    lines.append(f'{indent}</GanttChartField>')


def emit_calendar(lines, el, name, eid, indent):
    lines.append(f'{indent}<CalendarField name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    if el.get('path'):
        lines.append(f'{inner}<DataPath>{el["path"]}</DataPath>')

    emit_title(lines, el, name, inner, auto=not el.get('path'))
    emit_common_flags(lines, el, inner)

    if el.get('titleLocation'):
        loc_map = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom', 'auto': 'Auto'}
        loc = loc_map.get(str(el['titleLocation']), str(el['titleLocation']))
        lines.append(f'{inner}<TitleLocation>{loc}</TitleLocation>')

    emit_layout(lines, el, inner)

    # Календарно-специфичные свойства (порядок схемы: после layout, до companions)
    if el.get('selectionMode'):
        lines.append(f'{inner}<SelectionMode>{el["selectionMode"]}</SelectionMode>')
    if el.get('showCurrentDate') is not None:
        lines.append(f'{inner}<ShowCurrentDate>{"true" if el["showCurrentDate"] else "false"}</ShowCurrentDate>')
    if el.get('widthInMonths') is not None:
        lines.append(f'{inner}<WidthInMonths>{el["widthInMonths"]}</WidthInMonths>')
    if el.get('heightInMonths') is not None:
        lines.append(f'{inner}<HeightInMonths>{el["heightInMonths"]}</HeightInMonths>')
    if el.get('showMonthsPanel') is not None:
        lines.append(f'{inner}<ShowMonthsPanel>{"true" if el["showMonthsPanel"] else "false"}</ShowMonthsPanel>')

    # Оформление (цвета/шрифты/граница) — перед компаньонами
    emit_appearance(lines, el, inner, 'field')

    # Companions
    emit_companion_panel(lines, 'ContextMenu', f'{name}\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u043d\u043e\u0435\u041c\u0435\u043d\u044e', inner, el.get('contextMenu'))
    emit_companion(lines, 'ExtendedTooltip', f'{name}\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u043d\u0430\u044f\u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430', inner, el.get('extendedTooltip'))

    emit_events(lines, el, name, inner, 'calendar')

    lines.append(f'{indent}</CalendarField>')


def emit_command_bar(lines, el, name, eid, indent):
    lines.append(f'{indent}<CommandBar name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    if el.get('commandSource'):
        lines.append(f'{inner}<CommandSource>{el["commandSource"]}</CommandSource>')

    if el.get('autofill') is True:
        lines.append(f'{inner}<Autofill>true</Autofill>')

    # CommandBar хранит HorizontalLocation фактически (включая Auto); ≠ дополнениям (Auto=скип)
    if el.get('horizontalLocation'):
        _hlv = {'auto': 'Auto', 'left': 'Left', 'right': 'Right', 'center': 'Center'}.get(str(el['horizontalLocation']).lower(), str(el['horizontalLocation']))
        lines.append(f'{inner}<HorizontalLocation>{_hlv}</HorizontalLocation>')

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t', in_cmd_bar=True)
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</CommandBar>')


def emit_popup(lines, el, name, eid, indent):
    lines.append(f'{indent}<Popup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner, auto=True)
    emit_common_flags(lines, el, inner)

    # Источник команд попапа (после Title/ToolTip, перед компаньоном) — как у ButtonGroup/CommandBar
    if el.get('commandSource'):
        lines.append(f'{inner}<CommandSource>{el["commandSource"]}</CommandSource>')

    emit_command_picture(lines, el.get('picture'), el.get('loadTransparent'), inner)

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')
    emit_layout(lines, el, inner)

    # Оформление попапа (TitleTextColor / TitleFont) — перед компаньоном
    emit_appearance(lines, el, inner, 'field')

    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    # Children
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t', in_cmd_bar=True)
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</Popup>')


def emit_button_group(lines, el, name, eid, indent):
    lines.append(f'{indent}<ButtonGroup name="{name}" id="{eid}"{di_attr(el)}>')
    inner = f'{indent}\t'

    emit_title(lines, el, name, inner)

    if el.get('commandSource'):
        lines.append(f'{inner}<CommandSource>{el["commandSource"]}</CommandSource>')

    if el.get('representation'):
        lines.append(f'{inner}<Representation>{el["representation"]}</Representation>')

    emit_common_flags(lines, el, inner)
    emit_layout(lines, el, inner)

    # Companion: ExtendedTooltip
    emit_companion(lines, 'ExtendedTooltip', f'{name}РасширеннаяПодсказка', inner, el.get('extendedTooltip'))

    # Children (кнопки в контексте командной панели)
    if el.get('children') and len(el['children']) > 0:
        lines.append(f'{inner}<ChildItems>')
        for child in el['children']:
            emit_element(lines, child, f'{inner}\t', in_cmd_bar=True)
        lines.append(f'{inner}</ChildItems>')

    lines.append(f'{indent}</ButtonGroup>')


# --- Attribute emitter ---


def _normalize_synonyms(el):
    if not isinstance(el, dict):
        return
    # Companion-панели (объект/массив-значение) → commandBar/contextMenu
    normalize_panel_synonyms(el)
    # Тип-синонимы: commandBar/autoCommandBar → элемент-тип ТОЛЬКО при строковом значении
    synonyms = {'commandBar': 'cmdBar', 'autoCommandBar': 'autoCmdBar', 'extTooltip': 'extendedTooltip'}
    for src, dst in synonyms.items():
        if src in el and dst not in el:
            if src in STR_ONLY_TYPE_SYNONYMS and not isinstance(el[src], str):
                continue
            el[dst] = el.pop(src)
    # Рекурсия в детей панелей (commandBar/contextMenu)
    for pk in ('commandBar', 'contextMenu'):
        pv = el.get(pk)
        kids = pv if isinstance(pv, list) else (pv.get('children') if isinstance(pv, dict) else None)
        if isinstance(kids, list):
            for child in kids:
                _normalize_synonyms(child)
    if isinstance(el.get('children'), list):
        for child in el['children']:
            _normalize_synonyms(child)
    if isinstance(el.get('columns'), list):
        for child in el['columns']:
            _normalize_synonyms(child)


def _apply_dlist_table_heuristic(el, list_name, has_main_table):
    if not isinstance(el, dict):
        return
    if el.get('table') is not None and str(el.get('path', '')).lower() == list_name.lower():
        # Маркер дин-список-таблицы → emit_table эмитит блок свойств
        el['_dynList'] = True
        if 'tableAutofill' not in el:
            el['tableAutofill'] = False
        if 'commandBarLocation' not in el:
            el['commandBarLocation'] = 'None'
        # RowPictureDataPath: умный дефолт <Список>.DefaultPicture, если ключ ОТСУТСТВУЕТ.
        # Декомпилятор опускает при rpdp == smart-default; реальное отсутствие → ""-маркер (не
        # перезатирается). Гейт has_main_table снят: дин-список без mainTable тоже несёт RowPictureDataPath.
        if 'rowPictureDataPath' not in el:
            el['rowPictureDataPath'] = f'{list_name}.DefaultPicture'
    if isinstance(el.get('children'), list):
        for child in el['children']:
            _apply_dlist_table_heuristic(child, list_name, has_main_table)


# Ключи типов — в порядке form-compile (ключ-свойство проверяется после типа, у которого он свойство)
ELEMENT_KEYS = list(TYPE_KEYS)


# ── 6. Find element by name recursively ─────────────────────

def find_element(start_node, target_name):
    for child in start_node:
        if not isinstance(child.tag, str):
            continue
        child_name = child.get("name")
        if child_name == target_name:
            return child
        ci = child.find("f:ChildItems", NS)
        if ci is not None:
            found = find_element(ci, target_name)
            if found is not None:
                return found
    return None


# ── 7. Detect indent level of a container's children ────────

def get_child_indent(container):
    for child_node in container:
        if not isinstance(child_node.tag, str):
            # text nodes - check preceding/following text
            pass
    # Check text content of container (tail/text)
    for i, child in enumerate(container):
        # Check text before this child
        if i == 0:
            txt = container.text
        else:
            txt = container[i - 1].tail
        if txt:
            m = re.search(r'\n(\t+)$', txt)
            if m:
                return m.group(1)

    # Fallback: count depth from root
    depth = 0
    current = container
    while current is not None:
        parent = current.getparent()
        if parent is None:
            break
        depth += 1
        current = parent
    return "\t" * (depth + 1)


# ── 8. Insert node into container ───────────────────────────

def insert_into_container(container, new_node, after_name, child_indent):
    ref_idx = None

    if after_name:
        # Find the after-element
        after_elem = None
        for i, child in enumerate(container):
            if isinstance(child.tag, str) and child.get("name") == after_name:
                after_elem = child
                ref_idx = i + 1
                break
        if after_elem is None:
            print(f"[WARN] after='{after_name}' not found in target container, appending at end")

    children = list(container)
    if ref_idx is not None:
        # Insert after the after-element
        if ref_idx < len(children):
            children[ref_idx - 1].tail = "\n" + child_indent
            children[ref_idx - 1].addnext(new_node)
            new_node.tail = "\n" + child_indent
        else:
            # Append at end
            if len(children) > 0:
                children[-1].tail = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent
    else:
        # Append at end
        if len(children) > 0:
            # Insert before trailing whitespace (append after last child)
            children[-1].tail = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent
        else:
            # Container is empty
            container.text = "\n" + child_indent
            container.append(new_node)
            parent_indent = child_indent[:-1] if len(child_indent) > 1 else ""
            new_node.tail = "\n" + parent_indent


# ── 9. Generate fragment, parse, import nodes ────────────────

def parse_fragment(xml_text):
    frag_parser = etree.XMLParser(remove_blank_text=False)
    frag_doc = etree.fromstring(xml_text.encode("utf-8"), frag_parser)
    return frag_doc


def import_element_nodes(frag_root):
    nodes = []
    for child in frag_root:
        if isinstance(child.tag, str):
            nodes.append(child)
    return nodes


# ── 9b. Канонический порядок дочерних тегов элемента ────────
# В каком порядке платформа пишет свойства и вложенные узлы элемента формы. Построено по корпусу
# выгрузок (БП и ERP, 8.3.24, 17036 форм): для каждого типа элемента — граф «тег A раньше тега B»,
# противоречий нет. По нему новое свойство (set), новый ChildItems или Events встают туда, где их
# пишет платформа, — иначе первая же выгрузка из базы переставит их обратно.
CHILD_TAG_ORDER = {
    "AutoCommandBar": "HorizontalAlign Autofill ChildItems",
    "Button": "Type Visible TitleHeight UserVisible Representation DefaultButton SkipOnInput Enabled DefaultItem Width AutoMaxWidth MaxWidth Height AutoMaxHeight HorizontalStretch MaxHeight VerticalStretch GroupHorizontalAlign Check GroupVerticalAlign CommandName Parameter DataPath TextColor BackColor BorderColor Font Picture Title Shape ToolTipRepresentation RepresentationInContextMenu ShapeRepresentation PictureLocation LocationInCommandBar CommandUniqueness ExtendedTooltip",
    "ButtonGroup": "EnableContentChange Visible Title GroupVerticalAlign ToolTip HorizontalStretch GroupHorizontalAlign ToolTipRepresentation CommandSource Representation VerticalStretch ExtendedTooltip ChildItems",
    "CalendarField": "DataPath SkipOnInput Title TitleLocation ToolTip ToolTipRepresentation Width AutoMaxWidth Height HorizontalStretch SelectionMode ShowCurrentDate ShowMonthsPanel WidthInMonths HeightInMonths ContextMenu ExtendedTooltip Events",
    "ChartField": "DataPath Enabled Title TitleFont Visible TitleLocation GroupHorizontalAlign Width AutoMaxWidth MaxHeight MaxWidth Height AutoMaxHeight HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Events",
    "CheckBoxField": "DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip FooterHorizontalAlign HorizontalAlign ToolTipRepresentation Shortcut GroupHorizontalAlign VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode AutoCellHeight CellHyperlink FixingInTable ShowInHeader FooterDataPath HeaderPicture HeaderHorizontalAlign ShowInFooter CheckBoxType EditFormat ItemHeight ItemTitleHeight ItemWidth EqualItemsWidth ThreeState ContextMenu ExtendedTooltip Events",
    "ColumnGroup": "Visible Enabled ReadOnly UserVisible EnableContentChange Title GroupVerticalAlign TitleFont TitleTextColor ToolTip ToolTipRepresentation Width Height HorizontalStretch GroupHorizontalAlign VerticalStretch Group ShowTitle ShowInHeader HeaderDataPath HeaderHorizontalAlign HeaderFormat HeaderPicture FixingInTable ExtendedTooltip ChildItems",
    "CommandBar": "Enabled Visible EnableContentChange Title ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign HorizontalLocation CommandSource ExtendedTooltip ChildItems",
    "FormattedDocumentField": "DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleLocation CommandSet Font ToolTip EditMode Width AutoMaxWidth Height AutoMaxHeight BorderColor HorizontalStretch MaxWidth ContextMenu ExtendedTooltip Events",
    "GanttChartField": "DataPath DefaultItem TitleLocation Width Height HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Table Events",
    "GraphicalSchemaField": "DataPath DefaultItem ReadOnly Title TitleLocation WarningOnEditRepresentation Width Height Edit ContextMenu ExtendedTooltip Events",
    "HTMLDocumentField": "DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation ToolTipRepresentation Visible WarningOnEditRepresentation Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch Output BorderColor ContextMenu ExtendedTooltip Events",
    "InputField": "DataPath Visible UserVisible DefaultItem Enabled ReadOnly SkipOnInput Title TitleBackColor TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation WarningOnEditRepresentation WarningOnEdit Shortcut HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign EditMode CellHyperlink FixingInTable AutoCellHeight ShowInHeader HeaderHorizontalAlign HeaderPicture ShowInFooter FooterDataPath FooterText FooterTextColor FooterFont FooterHorizontalAlign FooterPicture Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch AllowInputEmptyMultipleValues MultipleValuesFont MultipleValuesTextColor MultipleValuesBackColor VerticalStretch Wrap MarkNegatives PasswordMode MultiLine ExtendedEdit DropListButton ChoiceButton ChoiceButtonRepresentation ClearButton SpinButton OpenButton CreateButton Mask ListChoiceMode ExtendedEditMultipleValues AutoChoiceIncomplete Format MultipleValuePictureShape QuickChoice ChoiceFoldersAndItems EditFormat AutoMarkIncomplete ChooseType AutoShowOpenButtonMode IncompleteChoiceMode ShowCheckBoxesInDropList MultipleValueDataPath MultipleValuePictureDataPath MultipleValuePresentDataPath SpellCheckingOnTextInput TypeDomainEnabled TextEdit AvailableTypes ChoiceForm ChoiceParameterLinks ChoiceParameters EditTextUpdate MinValue ChoiceButtonPicture MaxValue ChoiceList AutoCorrectionOnTextInput AutoShowClearButtonMode ChoiceListButton ChoiceListHeight DropListWidth TextColor BackColor BorderColor Font HeightControlVariant SpecialTextInputMode InputHint ChoiceHistoryOnInput TypeLink ContextMenu ExtendedTooltip Events",
    "LabelDecoration": "UserVisible Visible Enabled Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Shortcut Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink HorizontalAlign VerticalAlign BackColor BorderColor Border TitleHeight ContextMenu ExtendedTooltip Events",
    "LabelField": "DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode FixingInTable CellHyperlink AutoCellHeight FooterText ShowInHeader HeaderHorizontalAlign FooterDataPath HeaderPicture ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch MarkNegatives VerticalStretch Format Border BorderColor Hiperlink PasswordMode TextColor BackColor Font ContextMenu ExtendedTooltip Events",
    "Page": "Visible Enabled ReadOnly EnableContentChange UserVisible Title GroupVerticalAlign Shortcut TitleTextColor TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch ChildrenAlign Picture Format Group ChildItemsWidth HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign ShowTitle BackColor TitleDataPath ScrollOnCompress ExtendedTooltip ChildItems",
    "Pages": "Enabled ReadOnly EnableContentChange UserVisible Visible Title TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign PagesRepresentation CurrentRowUse ExtendedTooltip Events ChildItems",
    "PeriodField": "DataPath TitleLocation ContextMenu ExtendedTooltip",
    "PictureDecoration": "Enabled Visible Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink PictureSize Zoomable ImageScale NonselectedPictureText EnableStartDrag EnableDrag Picture BorderColor Border FileDragMode ContextMenu ExtendedTooltip Events",
    "PictureField": "DataPath TitleBackColor UserVisible Visible Enabled ReadOnly SkipOnInput Title TitleTextColor TitleLocation TitleHeight ToolTip GroupHorizontalAlign GroupVerticalAlign Shortcut ToolTipRepresentation HorizontalAlign WarningOnEditRepresentation EditMode AutoCellHeight FixingInTable CellHyperlink ShowInHeader FooterDataPath HeaderPicture FooterText HeaderHorizontalAlign ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch PictureSize Zoomable Hyperlink NonselectedPictureText EnableDrag TextColor ValuesPicture BorderColor Border Font FileDragMode ContextMenu ExtendedTooltip Events",
    "PlannerField": "DataPath TitleLocation ContextMenu ExtendedTooltip Events",
    "Popup": "UserVisible Visible EnableContentChange Title Shape TitleTextColor TitleFont ToolTip ToolTipRepresentation VerticalStretch Width HorizontalStretch Picture CommandSource Representation BackColor ShapeRepresentation BorderColor ExtendedTooltip ChildItems",
    "ProgressBarField": "DataPath Title Visible ReadOnly TitleLocation ToolTip ToolTipRepresentation Width AutoMaxHeight AutoMaxWidth HorizontalStretch MaxValue ShowPercent ContextMenu ExtendedTooltip",
    "RadioButtonField": "DataPath DefaultItem Enabled SkipOnInput UserVisible Visible ReadOnly Title TitleTextColor TitleFont TitleLocation FooterHorizontalAlign TitleHeight ToolTip ToolTipRepresentation EditMode GroupHorizontalAlign Shortcut VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit RadioButtonType ItemHeight ItemTitleHeight ItemWidth ColumnsCount EqualColumnsWidth ChoiceList Font TextColor ContextMenu ExtendedTooltip Events",
    "SpreadSheetDocumentField": "DataPath Enabled ReadOnly SkipOnInput UserVisible Visible DefaultItem Title TitleLocation DrawingSelectionShowMode FooterHorizontalAlign GroupHorizontalAlign ToolTip ToolTipRepresentation CommandSet Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch ShowGrid ShowHeaders VerticalScrollBar HorizontalScrollBar Protection SelectionShowMode Edit Output PointerType ShowGroups EnableStartDrag EnableDrag BorderColor ShowCellNames ShowRowAndColumnNames ViewScalingMode ContextMenu ExtendedTooltip Events",
    "Table": "Representation Visible UserVisible TitleLocation CommandBarLocation Autofill Enabled TitleHeight ReadOnly SkipOnInput DefaultItem ChangeRowSet ChangeRowOrder Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HeightInTableRows HeightControlVariant AutoMaxRowsCount MaxRowsCount ChoiceMode MultipleChoice RowInputMode SelectionMode RowSelectionMode Header FooterHeight HeaderHeight Footer HorizontalScrollBar VerticalScrollBar HorizontalLines VerticalLines UseAlternationRowColor AutoInsertNewRow AutoAddIncomplete AutoMarkIncomplete SearchOnInput InitialListView InitialTreeView HorizontalStretch Output VerticalStretch EnableStartDrag EnableDrag FileDragMode DataPath Font RowPictureDataPath RowsPicture BackColor BorderColor TextColor Title BehaviorOnHorizontalCompression GroupVerticalAlign Shortcut TitleTextColor TitleFont CommandSet ToolTip ToolTipRepresentation SearchStringLocation ViewStatusLocation SearchControlLocation GroupHorizontalAlign CurrentRowUse RefreshRequest AutoRefresh AutoRefreshPeriod Period ChoiceFoldersAndItems RestoreCurrentRow RowFilter TopLevelParent ShowRoot AllowRootChoice UpdateOnDataChange UserSettingsGroup AllowGettingCurrentRowURL ViewMode SettingsNamedItemDetailedRepresentation ContextMenu AutoCommandBar ExtendedTooltip SearchStringAddition ViewStatusAddition SearchControlAddition Events ChildItems",
    "TextDocumentField": "DataPath DefaultItem ReadOnly Title TitleFont TitleLocation EditMode ToolTip Width AutoMaxWidth Font MaxWidth Height AutoMaxHeight ContextMenu ExtendedTooltip Events",
    "TrackBarField": "DataPath Title TitleLocation HorizontalAlign ToolTip ToolTipRepresentation Width AutoMaxWidth HorizontalStretch MaxWidth Height AutoMaxHeight MinValue MarkingAppearance MaxValue LargeStep Step MarkingStep ContextMenu ExtendedTooltip Events",
    "UsualGroup": "UserVisible Visible Enabled ReadOnly EnableContentChange Title TitleTextColor TitleFont ToolTip ToolTipRepresentation Shortcut Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign Group ChildrenAlign HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign Behavior CollapsedRepresentationTitle Collapsed ControlRepresentation Representation CurrentRowUse Format ShowLeftMargin United ChildItemsWidth ShowTitle BackColor ThroughAlign TitleDataPath ExtendedTooltip ChildItems",
}
CHILD_RANK = {t: {c: i for i, c in enumerate(v.split(" "))} for t, v in CHILD_TAG_ORDER.items()}


def get_child_rank(parent_tag, child_tag):
    return CHILD_RANK.get(parent_tag, {}).get(child_tag, -1)


# ── 9c. Помощники операций над деревом элементов ────────────

def fail(msg):
    print(f"[ERROR] {msg}")
    sys.exit(1)


def _is_el(n):
    return isinstance(n.tag, str)


def get_next_element_sibling(n):
    s = n.getnext()
    while s is not None and not _is_el(s):
        s = s.getnext()
    return s


def get_first_element_child(n):
    for c in n:
        if _is_el(c):
            return c
    return None


def get_container_label(c):
    if c is root:
        return "корень формы"
    return c.get("name")


def _ws_before(node):
    """Пробельный текст перед узлом: tail предыдущего соседа или text родителя."""
    prev = node.getprevious()
    return prev.tail if prev is not None else node.getparent().text


def _set_ws_before(node, value):
    prev = node.getprevious()
    if prev is not None:
        prev.tail = value
    else:
        node.getparent().text = value


def _is_ws(s):
    return s is not None and s.strip() == "" and "\n" in s


# Вставка узла в контейнер: перед ref или в конец. Перевод строки с отступом идёт перед каждым
# дочерним узлом, у пустого контейнера — ещё и закрывающий с отступом родителя.
def insert_node_at(container, node, ref, indent):
    if ref is not None:
        node.tail = "\n" + indent
        ref.addprevious(node)
        return
    kids = list(container)
    last = kids[-1] if kids else None
    closing = last.tail if last is not None else container.text
    if _is_ws(closing):
        if last is not None:
            last.tail = "\n" + indent
        else:
            container.text = "\n" + indent
        container.append(node)
        node.tail = closing
    else:
        if last is not None:
            last.tail = "\n" + indent
        else:
            container.text = "\n" + indent
        container.append(node)
        parent_indent = indent[:-1] if len(indent) > 0 else ""
        node.tail = "\n" + parent_indent


# Дочерний узел элемента — на его каноническое место (см. 9b). Неизвестный тег — в конец.
def insert_child_canonical(parent, child):
    rank = get_child_rank(local_name(parent), local_name(child))
    ref = None
    if rank >= 0:
        for c in parent:
            if not _is_el(c):
                continue
            if get_child_rank(local_name(parent), local_name(c)) > rank:
                ref = c
                break
    insert_node_at(parent, child, ref, get_child_indent(parent))


# Узел вместе с переводом строки перед ним (как в PS: остаётся перевод строки после узла).
def remove_node_with_ws(node):
    parent = node.getparent()
    _set_ws_before(node, node.tail)
    node.tail = None
    parent.remove(node)


# Пустой ChildItems платформа не пишет никогда: у группы без элементов тега просто нет.
def remove_if_empty_child_items(ci):
    global root_ci
    if get_first_element_child(ci) is not None:
        return
    remove_node_with_ws(ci)
    if ci is root_ci:
        root_ci = None


ROOT_AFTER_CHILD_ITEMS = ['Attributes', 'Parameters', 'Commands', 'CommandInterface', 'ConditionalAppearance', 'BaseForm']


def get_or_create_child_items(container):
    global root_ci
    ci = container.find("f:ChildItems", NS)
    if ci is not None:
        return ci
    ci = etree.Element(f"{{{FORM_NS}}}ChildItems")
    if container is root:
        # ChildItems формы — после Events или AutoCommandBar, иначе перед первой из следующих секций
        insert_after = root.find("f:Events", NS)
        if insert_after is None:
            insert_after = root.find("f:AutoCommandBar", NS)
        ref = None
        if insert_after is not None:
            ref = get_next_element_sibling(insert_after)
        else:
            for c in root:
                if _is_el(c) and local_name(c) in ROOT_AFTER_CHILD_ITEMS:
                    ref = c
                    break
        insert_node_at(root, ci, ref, "\t")
        root_ci = ci
    else:
        insert_child_canonical(container, ci)
    return ci


def get_node_indent(node):
    ws = _ws_before(node)
    if _is_ws(ws):
        m = re.search(r'\n(\t*)$', ws)
        if m:
            return m.group(1)
    return ""


# Сдвиг отступов поддерева при смене глубины: каждый перевод строки внутри узла начинается с отступа
# старого места — меняем этот префикс на новый.
def set_subtree_indent(node, old_indent, new_indent):
    if old_indent == new_indent:
        return

    def fix(s):
        if s is None:
            return s
        m = re.match(r'^(\r?\n)(\t*)$', s)
        if m and m.group(2).startswith(old_indent):
            return m.group(1) + new_indent + m.group(2)[len(old_indent):]
        return s

    node.text = fix(node.text)
    for d in node.iterdescendants():
        d.tail = fix(d.tail)
        if _is_el(d):
            d.text = fix(d.text)


# Элемент формы по имени: дерево ChildItems и командная панель формы (с кнопками). BaseForm,
# реквизиты и команды не просматриваются. Имена в 1С регистронезависимы.
def find_form_element(name):
    target = name.lower()
    scopes = []
    if root_ci is not None:
        scopes.append(root_ci)
    acb_node = root.find("f:AutoCommandBar", NS)
    if acb_node is not None:
        if (acb_node.get("name") or "").lower() == target:
            return acb_node
        scopes.append(acb_node)
    # Элементы — узлы ChildItems и служебные узлы элемента (для внятного отказа); <Event name=…> и
    # прочие именованные свойства — не элементы.
    for s in scopes:
        for n in s.iterdescendants():
            if not _is_el(n) or n.get("name") is None:
                continue
            if etree.QName(n.tag).namespace != FORM_NS or n.get("name").lower() != target:
                continue
            if local_name(n.getparent()) == 'ChildItems' or local_name(n) in COMPANION_TAGS:
                return n
    return None


def get_nearest_table(node, inclusive):
    cur = node if inclusive else node.getparent()
    while cur is not None:
        if local_name(cur) == "Table":
            return cur
        cur = cur.getparent()
    return None


def is_inside(node, anc):
    cur = node
    while cur is not None:
        if cur is anc:
            return True
        cur = cur.getparent()
    return False


# Позиция операции: контейнер + узел, перед которым вставлять (None — в конец).
# after/before — контейнер якоря; into — в конец (first — в начало); first без into — начало формы.
def resolve_position(op, ctx, required):
    after = op.get("after")
    before = op.get("before")
    into = op.get("into")
    if "first" in op and not isinstance(op.get("first"), bool):
        fail(f"{ctx}: first — true или false")
    first = op.get("first") is True
    if after and before:
        fail(f"{ctx}: укажи что-то одно — after или before")
    anchor_name = str(after) if after else (str(before) if before else None)
    if first and anchor_name:
        fail(f"{ctx}: first — это начало контейнера, вместе с after/before не задаётся")
    into_el = None
    if into:
        into_el = find_form_element(str(into))
        if into_el is None:
            fail(f"{ctx}: контейнер '{into}' не найден в форме")
    if anchor_name:
        anchor = find_form_element(anchor_name)
        if anchor is None:
            fail(f"{ctx}: элемент '{anchor_name}' не найден в форме")
        ci = anchor.getparent()
        if local_name(ci) != "ChildItems":
            fail(f"{ctx}: '{anchor_name}' — служебный узел ({local_name(anchor)}), рядом с ним ставить нельзя")
        container = ci.getparent()
        if into_el is not None and into_el is not container:
            fail(f"{ctx}: '{anchor_name}' лежит в '{get_container_label(container)}', а не в '{into}'")
        if after:
            return {"Container": container, "Ref": get_next_element_sibling(anchor), "Anchor": anchor,
                    "Desc": f"{get_container_label(container)}, после {anchor_name}"}
        return {"Container": container, "Ref": anchor, "Anchor": anchor,
                "Desc": f"{get_container_label(container)}, перед {anchor_name}"}
    if into_el is None and first:
        into_el = root
    if into_el is not None:
        ref = None
        if first:
            ci = into_el.find("f:ChildItems", NS)
            if ci is not None:
                ref = get_first_element_child(ci)
        where = "первым" if first else "в конец"
        return {"Container": into_el, "Ref": ref, "Anchor": None, "Desc": f"{get_container_label(into_el)}, {where}"}
    if required:
        fail(f"{ctx}: не указано, куда — нужен after, before или into")
    return None


CONTAINER_TAGS = ['UsualGroup', 'Page', 'Pages', 'Table', 'ColumnGroup', 'CommandBar', 'AutoCommandBar', 'ButtonGroup', 'Popup', 'ContextMenu']
BAR_TAGS = ['CommandBar', 'AutoCommandBar', 'ButtonGroup', 'Popup', 'ContextMenu']
BAR_ITEM_TAGS = ['Button', 'ButtonGroup', 'Popup']
ADDITION_TAGS = ['SearchStringAddition', 'ViewStatusAddition', 'SearchControlAddition']
TABLE_ITEM_TAGS = ['InputField', 'CheckBoxField', 'LabelField', 'PictureField', 'ColumnGroup']
COMPANION_TAGS = ['ContextMenu', 'ExtendedTooltip', 'AutoCommandBar', 'SearchStringAddition', 'ViewStatusAddition', 'SearchControlAddition']
DSL_TAG_MAP = {
    "radio": "RadioButtonField", "columnGroup": "ColumnGroup", "buttonGroup": "ButtonGroup",
    "searchString": "SearchStringAddition", "viewStatus": "ViewStatusAddition", "searchControl": "SearchControlAddition",
    "spreadsheet": "SpreadSheetDocumentField", "html": "HTMLDocumentField", "textDoc": "TextDocumentField",
    "formattedDoc": "FormattedDocumentField", "progressBar": "ProgressBarField", "trackBar": "TrackBarField",
    "chart": "ChartField", "ganttChart": "GanttChartField", "graphicalSchema": "GraphicalSchemaField",
    "planner": "PlannerField", "periodField": "PeriodField", "dendrogram": "DendrogramField",
    "group": "UsualGroup", "input": "InputField", "check": "CheckBoxField", "label": "LabelDecoration",
    "labelField": "LabelField", "table": "Table", "pages": "Pages", "page": "Page", "button": "Button",
    "picture": "PictureDecoration", "picField": "PictureField", "calendar": "CalendarField", "cmdBar": "CommandBar", "popup": "Popup",
}
DSL_TAG_MAP_LC = {k.lower(): v for k, v in DSL_TAG_MAP.items()}


# Может ли элемент типа nt лечь в container. node — переносимый узел (у добавления None).
def assert_placement(nt, name, node, container, ctx):
    is_root = container is root
    ct = "Form" if is_root else local_name(container)
    cl = get_container_label(container)
    if not is_root and ct not in CONTAINER_TAGS:
        fail(f"{ctx}: '{cl}' ({ct}) не контейнер — в него нельзя положить элемент")
    if node is not None and is_inside(container, node):
        fail(f"{ctx}: '{name}' нельзя перенести внутрь самого себя — '{cl}' лежит внутри '{name}'")
    if nt == 'Page' and ct != 'Pages':
        fail(f"{ctx}: страница '{name}' может лежать только в группе страниц (Pages), а '{cl}' — {ct}")
    if ct == 'Pages' and nt != 'Page':
        fail(f"{ctx}: в группе страниц '{cl}' лежат только страницы (Page), а '{name}' — {nt}")
    if ct in BAR_TAGS and nt not in BAR_ITEM_TAGS and nt not in ADDITION_TAGS:
        fail(f"{ctx}: в командной панели '{cl}' лежат только кнопки, группы кнопок, подменю и дополнения таблицы, а '{name}' — {nt}")
    # Группа кнопок и подменю — только внутри командной панели, меню, подменю или группы кнопок (по корпусу)
    if nt in ('ButtonGroup', 'Popup') and ct not in BAR_TAGS:
        fail(f"{ctx}: '{name}' ({nt}) лежит только в командной панели, контекстном меню, подменю или группе кнопок, а '{cl}' — {ct}")
    if nt == 'ColumnGroup' and get_nearest_table(container, True) is None:
        fail(f"{ctx}: группа колонок '{name}' может лежать только внутри таблицы")
    # Колонки таблицы — только поля и группы колонок (по корпусу других типов там нет);
    # командная панель и контекстное меню таблицы — свои правила выше.
    in_table = None if is_root else get_nearest_table(container, True)
    if in_table is not None and ct not in BAR_TAGS and nt not in TABLE_ITEM_TAGS:
        fail(f"{ctx}: в таблице '{in_table.get('name')}' лежат только колонки (поля и группы колонок), а '{name}' — {nt}")
    # Граница таблицы: колонки и поля табличной части привязаны к своей таблице. Кнопки — нет
    # (стандартная команда таблицы законно стоит и в командной панели формы).
    if node is not None and nt not in BAR_ITEM_TAGS:
        frm = get_nearest_table(node, False)
        to = None if is_root else get_nearest_table(container, True)
        if frm is not to:
            if frm is not None:
                fail(f"{ctx}: '{name}' принадлежит таблице '{frm.get('name')}' — вынести его за её пределы или в другую таблицу нельзя")
            fail(f"{ctx}: '{name}' не принадлежит таблице — внутрь таблицы '{to.get('name')}' его перенести нельзя")


def assert_op_keys(op, allowed, ctx):
    allowed_lc = [a.lower() for a in allowed]
    for k in op:
        if k.lower() not in allowed_lc:
            fail(f"{ctx}: неизвестный ключ '{k}'; допустимы: {', '.join(allowed)}")


def _names_of(v):
    items = v if isinstance(v, list) else [v]
    return [str(x) for x in items if x is not None and str(x) != ""]


# --- Добавление ---

chain_node = None
default_pos = None
op_log = []
added_count = 0
moved_count = 0
changed_count = 0


def invoke_add(op, type_key, idx):
    global chain_node, default_pos, added_count
    name = get_element_name(op, type_key)
    ctx = f"elements[{idx}] {type_key} '{name}'"
    # Имя уже есть в форме — на момент этой операции (удалённое раньше в списке — свободно)
    existing = find_form_element(name)
    if existing is not None:
        print(f"[ERROR] Element '{name}' already exists in form (id={existing.get('id')}) — element names must be unique")
        sys.exit(1)
    pos = resolve_position(op, ctx, False)
    if pos is None:
        # Без своей позиции — как раньше: верхние into/after, следующие встают за предыдущим.
        if chain_node is not None:
            c = chain_node.getparent().getparent()
            pos = {"Container": c, "Ref": get_next_element_sibling(chain_node), "Anchor": None,
                   "Desc": f"{get_container_label(c)}, после {chain_node.get('name')}"}
        else:
            if default_pos is None:
                default_pos = resolve_position(defn, "elements (верхние into/after)", False)
                if default_pos is None:
                    default_pos = {"Container": root, "Ref": None, "Anchor": None, "Desc": "корень формы, в конец"}
            pos = default_pos
        chained = True
    else:
        chained = False
    assert_placement(DSL_TAG_MAP[type_key], name, None, pos["Container"], ctx)

    # Эмиттеру — копия элемента без ключей позиции (это не свойства элемента)
    el = ci_json({k: v for k, v in op.items() if k.lower() not in ('into', 'after', 'before', 'first')})
    _normalize_synonyms(el)
    # Таблица динамического списка получает поведение списка, как в form-compile
    for a in root.findall("f:Attributes/f:Attribute", NS):
        t = a.find("f:Type/v8:Type", NS)
        if t is not None and (t.text or "").strip() == 'cfg:DynamicList':
            _apply_dlist_table_heuristic(el, a.get('name'), True)
    # Пул имён эмиттера — имена элементов формы на момент операции (без узлов событий)
    _seen_element_names.clear()
    for sc in get_element_scopes():
        for n in sc.iterdescendants():
            if _is_el(n) and n.get("name") is not None and etree.QName(n.tag).namespace == FORM_NS and \
                    (local_name(n.getparent()) == 'ChildItems' or local_name(n) in COMPANION_TAGS):
                _seen_element_names.add(n.get("name").lower())
    _current_table_name['name'] = None
    # Дополнение таблицы: источник — source или таблица, внутри которой оно лежит
    if DSL_TAG_MAP[type_key] in ADDITION_TAGS:
        if el.get('source'):
            src = find_form_element(str(el['source']))
            if src is None or local_name(src) != 'Table':
                fail(f"{ctx}: source '{el['source']}' — нет такой таблицы в форме")
            el['source'] = src.get('name')
        else:
            tbl = None if pos["Container"] is root else get_nearest_table(pos["Container"], True)
            if tbl is None:
                fail(f"{ctx}: укажите source — таблицу, к которой относится дополнение")
            _current_table_name['name'] = tbl.get('name')

    ci = get_or_create_child_items(pos["Container"])
    indent = get_child_indent(ci)
    # Внутри командной панели, меню, подменю или группы кнопок кнопка — кнопка панели
    in_bar = False
    cur = pos["Container"]
    while cur is not None:
        if _is_el(cur) and local_name(cur) in BAR_TAGS:
            in_bar = True
            break
        cur = cur.getparent()
    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    emit_element(xml_lines, el, indent, in_bar)
    X("</_F>")
    node = import_element_nodes(parse_fragment("\n".join(xml_lines)))[0]
    insert_node_at(ci, node, pos["Ref"], indent)
    if chained:
        chain_node = node

    path_str = f" -> {op['path']}" if op.get("path") else ""
    evt_names = [e.get('name') for e in node.findall("f:Events/f:Event", NS)]
    evt_str = " {" + ", ".join(evt_names) + "}" if evt_names else ""
    op_log.append(f"  + [{local_name(node)}] {name}{path_str}{evt_str} → {pos['Desc']}")
    added_count += 1


# --- Командная панель формы (autoCmdBar, как в form-compile) ---

# Кнопки из children — в командную панель формы (в конец, по порядку); autofill и horizontalAlign — её свойства.
def invoke_auto_cmd_bar(op, idx):
    ctx = f"elements[{idx}] autoCmdBar"
    acb_node = root.find("f:AutoCommandBar", NS)
    if acb_node is None:
        fail(f"{ctx}: у формы нет командной панели")
    assert_op_keys(op, ['autoCmdBar', 'children', 'autofill', 'horizontalAlign'], ctx)
    if 'autofill' in op:
        if not isinstance(op.get('autofill'), bool):
            fail(f"{ctx}: autofill — true или false")
        set_value_tag(acb_node, 'Autofill', 'true' if op['autofill'] else 'false')
        op_log.append(f"  * {acb_node.get('name')}: Autofill={'true' if op['autofill'] else 'false'}")
    if op.get('horizontalAlign'):
        set_simple_tag(acb_node, 'HorizontalAlign', str(op['horizontalAlign']))
        op_log.append(f"  * {acb_node.get('name')}: HorizontalAlign={op['horizontalAlign']}")
    children = op.get('children')
    for child in (children if isinstance(children, list) else [children]):
        if child is None:
            continue
        if not isinstance(child, dict):
            fail(f"{ctx}: в children — не элемент (нужна кнопка, группа кнопок или подменю)")
        for pk in ('into', 'after', 'before', 'first'):
            if any(k.lower() == pk for k in child):
                fail(f"{ctx}: у кнопок в children нет позиции — они встают в конец панели по порядку; для места укажите кнопку отдельным элементом с into и after/before")
        normalize_element_type_synonyms(child)
        tk = next((k for k in ELEMENT_KEYS if k in child), None)
        if tk is None:
            fail(f"{ctx}: в children — не элемент (нужна кнопка, группа кнопок или подменю)")
        c = ci_json(dict(child))
        c['into'] = acb_node.get('name')
        invoke_add(c, tk, idx)


# --- Перенос ---

def invoke_move(op, idx):
    global moved_count
    ctx = f"elements[{idx}] move"
    assert_op_keys(op, ['move', 'after', 'before', 'into', 'first'], ctx)
    names = _names_of(op.get("move"))
    if not names:
        fail(f"{ctx}: укажи имя элемента или список имён")
    nodes = []
    seen = set()
    for n in names:
        if n.lower() in seen:
            fail(f"{ctx}: '{n}' указан дважды")
        seen.add(n.lower())
        node = find_form_element(n)
        if node is None:
            fail(f"{ctx}: элемент '{n}' не найден в форме")
        if local_name(node.getparent()) != 'ChildItems' or local_name(node) in COMPANION_TAGS:
            fail(f"{ctx}: '{n}' — служебный узел ({local_name(node)}) своего элемента, переносится только вместе с ним")
        nodes.append(node)
    pos = resolve_position(op, ctx, True)
    for node in nodes:
        if node is pos["Anchor"]:
            fail(f"{ctx}: '{node.get('name')}' не может быть якорем собственного переноса")
        assert_placement(local_name(node), node.get('name'), node, pos["Container"], ctx)

    ref = pos["Ref"]
    desc = pos["Desc"]
    prev = None
    for node in nodes:
        name = node.get('name')
        if prev is not None:
            ref = get_next_element_sibling(prev)
            desc = f"{get_container_label(pos['Container'])}, после {prev.get('name')}"
        from_ci = node.getparent()
        target_ci = pos["Container"].find("f:ChildItems", NS)
        if from_ci is target_ci and (ref is node or ref is get_next_element_sibling(node)):
            op_log.append(f"  = {name}: уже на месте ({desc})")
            prev = node
            continue
        from_label = get_container_label(from_ci.getparent())
        # Отступ цели — до отцепления: если узел был в ней единственным, после отцепления
        # первым пробельным узлом окажется закрывающий с отступом родителя.
        new_indent = get_child_indent(target_ci) if target_ci is not None else None
        old_indent = get_node_indent(node)
        remove_node_with_ws(node)
        ci = get_or_create_child_items(pos["Container"])
        if new_indent is None:
            new_indent = get_child_indent(ci)
        insert_node_at(ci, node, ref, new_indent)
        set_subtree_indent(node, old_indent, new_indent)
        if from_ci is not ci:
            remove_if_empty_child_items(from_ci)
        op_log.append(f"  ~ {name}: {from_label} → {desc}")
        moved_count += 1
        prev = node


# --- Изменение свойств ---

# Умолчания платформы: в корпусе эти теги встречаются только с противоположным значением —
# значение по умолчанию платформа не пишет, и set его не пишет, а убирает тег.
TAG_DEFAULTS = {
    'Visible': 'true', 'Enabled': 'true', 'ReadOnly': 'false', 'ShowTitle': 'true', 'United': 'true', 'Collapsed': 'false',
    'AutoMaxWidth': 'true', 'AutoMaxHeight': 'true', 'Hyperlink': 'false', 'Hiperlink': 'false',
}
# Умолчания перечислений зависят от типа элемента: значение из области, которого в корпусе нет ни
# разу у этого типа (у таблицы TitleLocation=Auto пишется явно — там правило не действует).
ENUM_DEFAULTS = {
    'UsualGroup/Group': 'HorizontalIfPossible', 'Page/Group': 'Vertical', 'ColumnGroup/Group': 'Vertical',
    'UsualGroup/Representation': 'WeakSeparation', 'Button/Representation': 'Auto', 'Popup/Representation': 'Auto',
    'AutoCommandBar/Autofill': 'true',
}


def get_tag_default(nt, tag):
    if tag in TAG_DEFAULTS:
        return TAG_DEFAULTS[tag]
    if f"{nt}/{tag}" in ENUM_DEFAULTS:
        return ENUM_DEFAULTS[f"{nt}/{tag}"]
    if tag == 'TitleLocation' and nt != 'Table':
        return 'Auto'
    return None


TITLE_LOC_MAP = {'none': 'None', 'left': 'Left', 'right': 'Right', 'top': 'Top', 'bottom': 'Bottom', 'auto': 'Auto'}
# Ключи — словарь form-compile; Tags — кандидаты по типу элемента (у LabelField платформа пишет Hiperlink).
SET_PROPS = {
    'title': {'Tags': ['Title'], 'Kind': 'ml'},
    'tooltip': {'Tags': ['ToolTip'], 'Kind': 'ml'},
    'inputHint': {'Tags': ['InputHint'], 'Kind': 'ml'},
    'visible': {'Tags': ['Visible'], 'Kind': 'bool'},
    'hidden': {'Tags': ['Visible'], 'Kind': 'bool', 'Invert': True},
    'enabled': {'Tags': ['Enabled'], 'Kind': 'bool'},
    'disabled': {'Tags': ['Enabled'], 'Kind': 'bool', 'Invert': True},
    'readOnly': {'Tags': ['ReadOnly'], 'Kind': 'bool'},
    'skipOnInput': {'Tags': ['SkipOnInput'], 'Kind': 'bool'},
    'titleLocation': {'Tags': ['TitleLocation'], 'Kind': 'enum', 'Map': TITLE_LOC_MAP},
    'width': {'Tags': ['Width'], 'Kind': 'num'},
    'height': {'Tags': ['HeightInTableRows', 'Height'], 'Kind': 'num'},
    'maxWidth': {'Tags': ['MaxWidth'], 'Kind': 'num'},
    'maxHeight': {'Tags': ['MaxHeight'], 'Kind': 'num'},
    'autoMaxWidth': {'Tags': ['AutoMaxWidth'], 'Kind': 'bool'},
    'autoMaxHeight': {'Tags': ['AutoMaxHeight'], 'Kind': 'bool'},
    'horizontalStretch': {'Tags': ['HorizontalStretch'], 'Kind': 'bool'},
    'verticalStretch': {'Tags': ['VerticalStretch'], 'Kind': 'bool'},
    'multiLine': {'Tags': ['MultiLine'], 'Kind': 'bool'},
    'passwordMode': {'Tags': ['PasswordMode'], 'Kind': 'bool'},
    'choiceButton': {'Tags': ['ChoiceButton'], 'Kind': 'bool'},
    'clearButton': {'Tags': ['ClearButton'], 'Kind': 'bool'},
    'spinButton': {'Tags': ['SpinButton'], 'Kind': 'bool'},
    'dropListButton': {'Tags': ['DropListButton'], 'Kind': 'bool'},
    'markIncomplete': {'Tags': ['AutoMarkIncomplete'], 'Kind': 'bool'},
    'hyperlink': {'Tags': ['Hyperlink', 'Hiperlink'], 'Kind': 'bool'},
    'group': {'Tags': ['Group'], 'Kind': 'enum', 'Map': {'vertical': 'Vertical', 'horizontal': 'Horizontal', 'horizontalifpossible': 'HorizontalIfPossible', 'alwayshorizontal': 'AlwaysHorizontal', 'alwaysvertical': 'AlwaysVertical', 'incell': 'InCell'}},
    'behavior': {'Tags': ['Behavior'], 'Kind': 'enum', 'Map': {'usual': 'Usual', 'collapsible': 'Collapsible', 'popup': 'PopUp'}},
    'collapsed': {'Tags': ['Collapsed'], 'Kind': 'bool'},
    'representation': {'Tags': ['Representation'], 'Kind': 'repr'},
    'showTitle': {'Tags': ['ShowTitle'], 'Kind': 'bool'},
    'united': {'Tags': ['United'], 'Kind': 'bool'},
}
SET_PROPS_LC = {k.lower(): v for k, v in SET_PROPS.items()}
# Значения Representation — свои у каждого типа (по корпусу); ключи — как в form-compile.
REPR_MAPS = {
    'UsualGroup': {'none': 'None', 'normal': 'NormalSeparation', 'weak': 'WeakSeparation', 'strong': 'StrongSeparation'},
    'Table': {'list': 'List', 'tree': 'Tree', 'hierarchicallist': 'HierarchicalList'},
    'Button': {'auto': 'Auto', 'text': 'Text', 'picture': 'Picture', 'pictureandtext': 'PictureAndText'},
    'Popup': {'auto': 'Auto', 'text': 'Text', 'picture': 'Picture', 'pictureandtext': 'PictureAndText'},
    'ButtonGroup': {'usual': 'Usual', 'compact': 'Compact'},
}
XML_TAG_TO_DSL = {v: k for k, v in DSL_TAG_MAP.items()}


def get_prop_tag(spec, nt):
    for t in spec['Tags']:
        if get_child_rank(nt, t) >= 0:
            return t
    return None


def get_applicable_set_keys(nt):
    keys = []
    for k, spec in SET_PROPS.items():
        if k in ('hidden', 'disabled'):
            continue
        if get_prop_tag(spec, nt) is not None:
            keys.append(k)
    if get_child_rank(nt, 'Events') >= 0:
        keys.append('on')
    return keys


def set_simple_tag(node, tag, text):
    existing = node.find(f"f:{tag}", NS)
    if existing is not None:
        existing.text = text
        return
    el = etree.Element(f"{{{FORM_NS}}}{tag}")
    el.text = text
    insert_child_canonical(node, el)


# Значение по умолчанию платформа не пишет — и set его не пишет, а убирает тег.
def set_value_tag(node, tag, text):
    if get_tag_default(local_name(node), tag) == text:
        existing = node.find(f"f:{tag}", NS)
        if existing is not None:
            remove_node_with_ws(existing)
        return
    set_simple_tag(node, tag, text)


def set_ml_tag(node, tag, value):
    indent = get_child_indent(node)
    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    X(f"{indent}<{tag}>")
    if isinstance(value, str):
        # Строка меняет только русский текст: переводы на другие языки остаются как были
        items = []
        prev_el = node.find(f"f:{tag}", NS)
        has_ru = False
        if prev_el is not None:
            for it in prev_el.findall("v8:item", NS):
                lang_el = it.find("v8:lang", NS)
                lang = (lang_el.text or "") if lang_el is not None else ""
                if lang == 'ru':
                    items.append(("ru", value))
                    has_ru = True
                else:
                    content_el = it.find("v8:content", NS)
                    items.append((lang, (content_el.text or "") if content_el is not None else ""))
        if not has_ru:
            items = [("ru", value)] + items
    else:
        items = [(k, str(v)) for k, v in value.items()]
    for lang, text in items:
        X(f"{indent}\t<v8:item>")
        X(f"{indent}\t\t<v8:lang>{lang}</v8:lang>")
        X(f"{indent}\t\t<v8:content>{esc_xml_text(text)}</v8:content>")
        X(f"{indent}\t</v8:item>")
    X(f"{indent}</{tag}>")
    X("</_F>")
    new_el = import_element_nodes(parse_fragment("\n".join(xml_lines)))[0]
    existing = node.find(f"f:{tag}", NS)
    if existing is not None:
        # Атрибуты узла (formatted у заголовка надписи) переживают замену текста
        for k, v in existing.attrib.items():
            new_el.set(k, v)
        new_el.tail = existing.tail
        node.replace(existing, new_el)
        return
    if tag == 'Title' and local_name(node) == 'LabelDecoration':
        new_el.set('formatted', 'false')
    insert_child_canonical(node, new_el)


def add_element_events(node, on, handlers, ctx):
    global changed_count
    nt = local_name(node)
    name = node.get('name')
    if get_child_rank(nt, 'Events') < 0:
        fail(f"{ctx}: у {nt} '{name}' событий нет")
    dsl = XML_TAG_TO_DSL.get(nt)
    allowed = KNOWN_EVENTS.get(dsl, []) if dsl else []
    events = node.find("f:Events", NS)
    for evt in (on if isinstance(on, list) else [on]):
        if isinstance(evt, str) or not (isinstance(evt, dict) and evt.get("event")):
            evt_name = str(evt)
            call_type = ""
            handler = str(handlers.get(evt_name)) if handlers and handlers.get(evt_name) else get_handler_name(name, evt_name)
        else:
            evt_name = str(evt.get("event"))
            call_type = normalize_call_type(evt.get("callType"), name, evt_name)
            if evt.get("handler"):
                handler = str(evt.get("handler"))
            elif handlers and handlers.get(evt_name):
                handler = str(handlers.get(evt_name))
            else:
                handler = get_handler_name(name, evt_name)
        # Заимствованный элемент в расширении: событие без callType платформа читает как Before и так и пишет
        if not call_type and is_extension and test_borrowed(name, 'element'):
            call_type = 'Before'
        if allowed and evt_name not in allowed:
            print(f"[WARN] Unknown event '{evt_name}' for {dsl} '{name}'. Known: {', '.join(allowed)}")
        ct_str = f"[{call_type}]" if call_type else ""
        if events is not None:
            dup = None
            for e in events.findall("f:Event", NS):
                if (e.get('name') or "").lower() == evt_name.lower() and (e.get('callType') or "").lower() == call_type.lower():
                    dup = e
                    break
            if dup is not None:
                if (dup.text or "").lower() == handler.lower():
                    op_log.append(f"  = {name}: событие {evt_name}{ct_str} -> {handler} уже есть")
                    continue
                fail(f"{ctx}: у '{name}' событие {evt_name}{ct_str} уже обрабатывает '{dup.text}' — второй обработчик не повесить")
        if events is None:
            events = etree.Element(f"{{{FORM_NS}}}Events")
            insert_child_canonical(node, events)
        ev = etree.Element(f"{{{FORM_NS}}}Event")
        ev.set('name', evt_name)
        if call_type:
            ev.set('callType', call_type)
        ev.text = handler
        insert_node_at(events, ev, None, get_child_indent(events))
        op_log.append(f"  * {name}: событие {evt_name}{ct_str} -> {handler}")
        changed_count += 1


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def invoke_set(op, idx):
    global changed_count
    ctx = f"elements[{idx}] set"
    names = _names_of(op.get("set"))
    if not names:
        fail(f"{ctx}: укажи имя элемента или список имён")
    props = [(k, op[k]) for k in op if k.lower() != 'set']
    if not props:
        fail(f"{ctx}: не указано, что менять")
    forbidden = ['name', 'path', 'children', 'columns']
    for n in names:
        node = find_form_element(n)
        if node is None:
            fail(f"{ctx}: элемент '{n}' не найден в форме")
        nt = local_name(node)
        c = f"{ctx} '{n}'"
        probe_props = {}
        for key, v in props:
            kl = key.lower()
            if kl == 'handlers':
                if not op.get("on"):
                    fail(f"{c}: handlers задаются вместе с on")
                continue
            if kl == 'on':
                add_element_events(node, v, op.get("handlers"), c)
                continue
            if kl == 'events':
                if not isinstance(v, dict):
                    fail(f"{c}: events — объект {{ Событие: обработчик }}")
                on = [{'event': e, 'handler': h, 'callType': ct} for e, h, ct in get_event_pairs(op, n)]
                add_element_events(node, on, None, c)
                continue
            if kl in forbidden or (kl == (XML_TAG_TO_DSL.get(nt) or '').lower() and kl != 'group'):
                fail(f"{c}: '{key}' через set не меняется (имя и привязку не трогаем — на них ссылаются модуль и расширения; состав — через move)")
            if kl in ('into', 'after', 'before', 'first'):
                fail(f"{c}: '{key}' — место элемента меняет move, не set")
            if kl not in SET_PROPS_LC:
                # Остальные ключи элемента — как в form-compile, через общий эмиттер
                probe_props[key] = v
                continue
            spec = SET_PROPS_LC[kl]
            tag = get_prop_tag(spec, nt)
            if tag is None:
                fail(f"{c}: свойство '{key}' к {nt} не применимо; доступно: {', '.join(get_applicable_set_keys(nt))} и остальные ключи элемента из form-compile")
            if v is None:
                existing = node.find(f"f:{tag}", NS)
                if existing is not None:
                    remove_node_with_ws(existing)
                op_log.append(f"  * {n}: {key} сброшено")
                changed_count += 1
                continue
            kind = spec['Kind']
            if kind == 'ml':
                ml_ok = isinstance(v, str) or (isinstance(v, dict) and len(v) > 0 and all(isinstance(x, str) for x in v.values()))
                if not ml_ok:
                    fail(f"{c}: {key} — строка или объект {{ru, en, ...}} со строковыми значениями")
                set_ml_tag(node, tag, v)
                shown = v if isinstance(v, str) else " ".join(f"{k2}:{v2}" for k2, v2 in v.items())
                op_log.append(f"  * {n}: {key}=\"{shown}\"")
            elif kind == 'bool':
                if not isinstance(v, bool):
                    fail(f"{c}: {key} — true или false")
                if spec.get('Invert'):
                    v = not v
                text = 'true' if v else 'false'
                set_value_tag(node, tag, text)
                op_log.append(f"  * {n}: {tag}={text}")
            elif kind == 'num':
                if not _is_num(v) or isinstance(v, float) or v < 0:
                    fail(f"{c}: {key} — целое неотрицательное число")
                set_simple_tag(node, tag, str(v))
                op_log.append(f"  * {n}: {tag}={v}")
            elif kind == 'enum':
                mapped = spec['Map'].get(str(v).lower())
                if not mapped:
                    fail(f"{c}: {key}='{v}' — допустимо: {', '.join(sorted(spec['Map'].keys()))}")
                set_value_tag(node, tag, mapped)
                op_log.append(f"  * {n}: {tag}={mapped}")
            elif kind == 'repr':
                rmap = REPR_MAPS.get(nt)
                if rmap is None:
                    fail(f"{c}: свойство '{key}' к {nt} не применимо; доступно: {', '.join(get_applicable_set_keys(nt))} и остальные ключи элемента из form-compile")
                text = rmap.get(str(v).lower())
                if not text:
                    fail(f"{c}: representation='{v}' — допустимо: {', '.join(sorted(rmap.keys()))}")
                set_value_tag(node, tag, text)
                op_log.append(f"  * {n}: {tag}={text}")
            changed_count += 1
        if probe_props:
            # Контекст пробы — все свойства операции: от них зависит, как эмиттер пишет остальные
            pp_lc = {k.lower() for k in probe_props}
            context = {k: v for k, v in props
                       if k.lower() not in ('on', 'handlers', 'events') and v is not None and k.lower() not in pp_lc}
            invoke_set_by_emitter(node, probe_props, context, op, c)


# --- set: ключи элемента вне таблицы выше — через общий эмиттер form-compile ---
# Элемент эмитится без свойства и с ним; что различается, то свойство и пишет в XML. Так set знает
# все ключи form-compile и пишет их ровно так же, как при создании формы.

PROBE_TYPE_VALUES = {'group': 'vertical', 'columnGroup': 'vertical'}


def invoke_set_probe(node, props):
    global next_elem_id
    nt = local_name(node)
    dsl = XML_TAG_TO_DSL[nt]
    name = node.get('name')
    h = {dsl: PROBE_TYPE_VALUES.get(dsl, name), 'name': name}
    dp = node.find("f:DataPath", NS)
    if dp is not None:
        h['path'] = dp.text or ''
    for k, v in props.items():
        h[k] = v
    el = ci_json(json.loads(json.dumps(h, ensure_ascii=False)))
    _normalize_synonyms(el)
    for a in root.findall("f:Attributes/f:Attribute", NS):
        t = a.find("f:Type/v8:Type", NS)
        if t is not None and (t.text or "").strip() == 'cfg:DynamicList':
            _apply_dlist_table_heuristic(el, a.get('name'), True)
    save_id = next_elem_id
    _seen_element_names.clear()
    tbl = get_nearest_table(node, False)
    _current_table_name['name'] = tbl.get('name') if tbl is not None else None
    in_bar = False
    cur = node.getparent()
    while cur is not None:
        if _is_el(cur) and local_name(cur) in BAR_TAGS:
            in_bar = True
            break
        cur = cur.getparent()
    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        emit_element(xml_lines, el, get_node_indent(node), in_bar)
    X("</_F>")
    next_elem_id = save_id
    frag = parse_fragment("\n".join(xml_lines))
    pe = next((ch for ch in frag if isinstance(ch.tag, str)), None)
    return {'El': pe, 'Messages': [l for l in buf.getvalue().splitlines() if l.strip()]}


def _probe_text(ch):
    t = etree.tostring(ch, encoding='unicode', with_tail=False)
    return re.sub(r'\s+', ' ', re.sub(r' id="-?\d+"', '', t))


# Свойства узла: дочерние теги (без состава и событий) и атрибуты; спутники (меню, подсказка,
# панель) — отдельно, их свойства сравниваются так же.
def get_probe_parts(e):
    tags, comps, attrs = {}, {}, {}
    for ch in e:
        if not _is_el(ch):
            continue
        ln = local_name(ch)
        if ln == 'Events':
            continue
        if ln == 'ChildItems':
            comps['#items'] = _probe_text(ch)
            continue
        if ln in COMPANION_TAGS and ch.get('name') is not None:
            comps[ln] = ch
            continue
        tags[ln] = tags.get(ln, '') + _probe_text(ch)
    for a, v in e.attrib.items():
        if a not in ('name', 'id'):
            attrs[a] = v
    return {'Tags': tags, 'Comps': comps, 'Attrs': attrs}


def get_probe_diff(b, p):
    pb, pp = get_probe_parts(b), get_probe_parts(p)
    d = {'Tags': [], 'Attrs': [], 'Comps': [], 'Items': False}
    for t in list(dict.fromkeys(list(pb['Tags']) + list(pp['Tags']))):
        if pb['Tags'].get(t) != pp['Tags'].get(t):
            d['Tags'].append(t)
    for a in sorted(set(pb['Attrs']) | set(pp['Attrs'])):
        if pb['Attrs'].get(a) != pp['Attrs'].get(a):
            d['Attrs'].append(a)
    if pb['Comps'].get('#items') != pp['Comps'].get('#items'):
        d['Items'] = True
    for cn in sorted(k for k in pp['Comps'] if k != '#items'):
        if pb['Comps'].get(cn) is None:
            continue
        sub = get_probe_diff(pb['Comps'][cn], pp['Comps'][cn])
        # Состав спутника (кнопки меню, панели) — тоже состав
        if sub['Items']:
            d['Items'] = True
        if test_probe_diff(sub):
            d['Comps'].append({'Tag': cn, 'Diff': sub})
    return d


def test_probe_diff(d):
    return (len(d['Tags']) + len(d['Attrs']) + len(d['Comps'])) > 0 or d['Items']


# Есть ли в узле хоть что-то из того, что описывает разница (для сброса к умолчанию).
def test_probe_diff_present(target, d):
    for t in d['Tags']:
        if target.find(f"f:{t}", NS) is not None:
            return True
    for a in d['Attrs']:
        if target.get(a) is not None:
            return True
    for cd in d['Comps']:
        tc = target.find(f"f:{cd['Tag']}", NS)
        if tc is not None and test_probe_diff_present(tc, cd['Diff']):
            return True
    return False


def get_probe_diff_label(d):
    parts = list(d['Tags']) + [f"@{a}" for a in d['Attrs']]
    for cd in d['Comps']:
        parts += [f"{cd['Tag']}/{x}" for x in get_probe_diff_label(cd['Diff'])]
    return parts


# Перенести в узел то, что различается: теги пробы заменяют свои (нет в пробе — тег убирается).
def apply_probe_diff(target, probe_el, d, remove_only):
    for t in d['Tags']:
        for x in target.findall(f"f:{t}", NS):
            remove_node_with_ws(x)
        if remove_only:
            continue
        for pn in probe_el.findall(f"f:{t}", NS):
            imp = copy.deepcopy(pn)
            imp.tail = None
            if get_child_rank(local_name(target), t) >= 0:
                insert_child_canonical(target, imp)
                continue
            # Тега нет в корпусном порядке — встаёт перед первым следующим за ним в пробе тегом узла
            ref = None
            sib = pn.getnext()
            while sib is not None and ref is None:
                if _is_el(sib):
                    ref = target.find(f"f:{local_name(sib)}", NS)
                sib = sib.getnext()
            insert_node_at(target, imp, ref, get_child_indent(target))
    for a in d['Attrs']:
        if not remove_only and probe_el.get(a) is not None:
            target.set(a, probe_el.get(a))
        elif a in target.attrib:
            del target.attrib[a]
    for cd in d['Comps']:
        tc = target.find(f"f:{cd['Tag']}", NS)
        pc = probe_el.find(f"f:{cd['Tag']}", NS) if probe_el is not None else None
        if tc is not None:
            apply_probe_diff(tc, pc, cd['Diff'], remove_only)
        elif not remove_only:
            fail(f"у '{target.get('name')}' нет {cd['Tag']} — свойство некуда записать")


def get_probe_owner_tags(key):
    for tag, k, _kind in GENERIC_SCALARS:
        if k.lower() == key.lower():
            return [tag]
    for k, spec in APPEARANCE_SPEC.items():
        if k.lower() == key.lower():
            return [spec[0]]
    return []


# Теги, которые set через эмиттер не трогает: привязка и тип. Теги ручной таблицы (Title, ToolTip…)
# проба переписывает, только если их ключ задан в той же операции, — иначе эмиттер, не зная их
# значения, затёр бы его своим.
PROBE_LOCKED_TAGS = ['DataPath', 'CommandName', 'Type']


def assert_probe_tags(d, k, op, c):
    for t in d['Tags']:
        if t in PROBE_LOCKED_TAGS:
            fail(f"{c}: '{k}' меняет {t} — привязка и тип элемента через set не меняются")
    for t in d['Tags']:
        owners = [sk for sk, spec in SET_PROPS.items() if t in spec['Tags']]
        if owners and not any(o in op for o in owners):
            fail(f"{c}: '{k}' меняет и {t} — укажите в той же операции {' или '.join(owners)}")


def invoke_set_by_emitter(node, props, context, op, c):
    global changed_count
    n = node.get('name')
    nt = local_name(node)
    if nt not in XML_TAG_TO_DSL:
        fail(f"{c}: у {nt} меняются только: {', '.join(get_applicable_set_keys(nt))}")
    st = dict(context)
    for k, v in props.items():
        if v is not None:
            st[k] = v
    full = invoke_set_probe(node, st)
    if local_name(full['El']) != nt:
        tk = [k for k in props if k.lower() in DSL_TAG_MAP_LC]
        fail(f"{c}: '{', '.join(tk)}' — ключ типа элемента; тип через set не меняется")
    removals, applies = [], []
    for k, v in props.items():
        rest = {k2: v2 for k2, v2 in st.items() if k2 != k}
        without = invoke_set_probe(node, rest)
        if v is None:
            # Сброс: убрать то, что ключ пишет при любом значении
            owned = get_probe_owner_tags(k)
            d = {'Tags': owned, 'Attrs': [], 'Comps': [], 'Items': False}
            if not owned:
                for alt in (True, False):
                    wa = dict(rest)
                    wa[k] = alt
                    pa = invoke_set_probe(node, wa)
                    if any("unknown key '" in m for m in pa['Messages']):
                        break
                    da = get_probe_diff(without['El'], pa['El'])
                    if test_probe_diff(da):
                        d = da
                        break
            if not test_probe_diff(d):
                fail(f"{c}: '{k}' сбросить нельзя — неизвестное свойство или у него нет значения по умолчанию; укажите значение")
            assert_probe_tags(d, k, op, c)
            if test_probe_diff_present(node, d):
                removals.append(d)
                op_log.append(f"  * {n}: {k} сброшено")
                changed_count += 1
            else:
                op_log.append(f"  = {n}: {k} — уже по умолчанию")
            continue
        d = get_probe_diff(without['El'], full['El'])
        if test_probe_diff(d):
            if d['Items']:
                fail(f"{c}: '{k}' меняет состав '{n}' — элементы добавляются отдельными операциями")
            assert_probe_tags(d, k, op, c)
            applies.append(d)
            if isinstance(v, bool):
                shown = f"={'true' if v else 'false'}"
            elif isinstance(v, (str, int)):
                shown = f"={v}"
            else:
                shown = ""
            op_log.append(f"  * {n}: {k}{shown} → {', '.join(get_probe_diff_label(d))}")
            changed_count += 1
            continue
        # Разницы нет: ключ неизвестен, значение не распознано или совпадает с умолчанием платформы
        msgs = full['Messages']
        if any(re.search(r"unknown key '" + re.escape(k) + "'", m, re.I) for m in msgs):
            fail(f"{c}: неизвестное свойство '{k}' — ключи те же, что у элемента в form-compile")
        vv = [m2.group(1) for m2 in (re.search(r'Valid values: (.*?)\. Value ignored', m) for m in msgs) if m2]
        if vv:
            fail(f"{c}: {k}='{v}' — значение не распознано; допустимо: {vv[0]}")
        if isinstance(v, bool):
            wa = dict(rest)
            wa[k] = not v
            pa = invoke_set_probe(node, wa)
            da = get_probe_diff(without['El'], pa['El'])
            if test_probe_diff(da):
                assert_probe_tags(da, k, op, c)
                if test_probe_diff_present(node, da):
                    removals.append(da)
                    op_log.append(f"  * {n}: {k}={'true' if v else 'false'} — умолчание платформы, {', '.join(get_probe_diff_label(da))} не пишется")
                    changed_count += 1
                else:
                    op_log.append(f"  = {n}: {k}={'true' if v else 'false'} — уже по умолчанию")
                continue
        fail(f"{c}: '{k}' к {nt} не применимо или значение совпадает с умолчанием (чтобы вернуть умолчание — null)")
    for r in removals:
        apply_probe_diff(node, None, r, True)
    for a in applies:
        apply_probe_diff(node, full['El'], a, False)


# --- Удаление ---

DCSSET_NS = "http://v8.1c.ru/8.1/data-composition-system/settings"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
NS["dcsset"] = DCSSET_NS
remove_log = []
removed_count = 0
left_handlers = []
_module_scan = None


# Модуль формы — рядом с Form.xml: <...>/Ext/Form/Module.bsl. Сканер BSL: строковые литералы (с "" и
# многострочными продолжениями «|») и комментарии // отделяются от кода, номера строк сохраняются.
def get_module_scan():
    global _module_scan
    if _module_scan is not None:
        return _module_scan
    scan = {"Exists": False, "Raw": "", "Lines": [], "Code": [], "Literals": []}
    path = os.path.join(os.path.dirname(resolved_form_path), "Form", "Module.bsl")
    if os.path.exists(path):
        scan["Exists"] = True
        with open(path, encoding="utf-8-sig", newline="") as fh:
            scan["Raw"] = fh.read()
        lines = scan["Raw"].replace("\r", "").split("\n")
        code = []
        lits = []
        in_str = False
        cur = None
        cur_line = 0
        cur_prefix = ""
        for i, line in enumerate(lines):
            sb = []
            j = 0
            if in_str:
                # продолжение многострочного литерала: пробелы, затем «|»
                while j < len(line) and line[j] in (' ', '\t'):
                    j += 1
                if j < len(line) and line[j] == '|':
                    j += 1
                cur += "\n"
            while j < len(line):
                c = line[j]
                if in_str:
                    if c == '"':
                        if j + 1 < len(line) and line[j + 1] == '"':
                            cur += '"'
                            j += 2
                            continue
                        in_str = False
                        lits.append({"Line": cur_line, "Text": cur, "Prefix": cur_prefix})
                        sb.append('""')
                        j += 1
                        continue
                    cur += c
                    j += 1
                    continue
                if c == '/' and j + 1 < len(line) and line[j + 1] == '/':
                    break
                if c == '"':
                    in_str = True
                    cur = ""
                    cur_line = i + 1
                    cur_prefix = "".join(sb)
                    j += 1
                    continue
                sb.append(c)
                j += 1
            code.append("".join(sb))
        scan["Lines"] = lines
        scan["Code"] = code
        scan["Literals"] = lits
    _module_scan = scan
    return scan


# Где имя элемента/команды передают строкой: Найти("X"), ПолеКомпоновкиДанных("X"), ПутьКДанным = "X",
# УстановитьСвойствоЭлементаФормы(Элементы, "X", …); реквизита — ещё РеквизитФормыВЗначение("X") и
# ЗначениеВРеквизитФормы(…, "X").
ITEM_LITERAL_CONTEXT = r'((?<!\w)(Найти|Find|ПолеКомпоновкиДанных|DataCompositionField)\s*\(\s*|(?<!\w)(ПутьКДанным|DataPath)\s*=\s*|(?<!\w)(Элементы|Items)\s*,\s*)$'
ATTR_LITERAL_CONTEXT = r'((?<!\w)(ПолеКомпоновкиДанных|DataCompositionField|РеквизитФормыВЗначение|FormAttributeToValue)\s*\(\s*|(?<!\w)(ЗначениеВРеквизитФормы|ValueToFormAttribute)\s*\(.*,\s*|(?<!\w)(ПутьКДанным|DataPath)\s*=\s*)$'


# Номера строк модуля, где есть ссылка на имя. kind: element | command | attribute.
def find_module_refs(name, kind):
    scan = get_module_scan()
    hits = set()
    if not scan["Exists"]:
        return []
    n = re.escape(name)
    for i, code in enumerate(scan["Code"]):
        if kind == 'element':
            if re.search(rf"(?<!\w)(Элементы|Items|ПодчиненныеЭлементы|ChildItems)\s*\.\s*{n}(?!\w)", code, re.I):
                hits.add(i + 1)
        elif kind == 'command':
            if re.search(rf"(?<!\w)(Команды|Commands)\s*\.\s*{n}(?!\w)", code, re.I):
                hits.add(i + 1)
        else:
            # Реквизит формы: имя целым словом не после точки; после точки — только ЭтаФорма./ЭтотОбъект.
            for m in re.finditer(rf"(?<!\w){n}(?!\w)", code, re.I):
                before = code[:m.start()]
                if re.search(r'\.\s*$', before):
                    if re.search(r'(?<![\w.])(ЭтаФорма|ЭтотОбъект|ThisForm|ThisObject)\s*\.\s*$', before, re.I):
                        hits.add(i + 1)
                else:
                    hits.add(i + 1)
    # Строкой имя передают только в узком наборе вызовов (по корпусу) — остальные литералы
    # (параметры запроса, ключи структур) с именем совпадают случайно и ссылкой не считаются.
    ctx_pat = ATTR_LITERAL_CONTEXT if kind == 'attribute' else ITEM_LITERAL_CONTEXT
    for lit in scan["Literals"]:
        t = lit["Text"]
        match = t.lower() == name.lower() or (kind == 'attribute' and t.lower().startswith(name.lower() + "."))
        if match and re.search(ctx_pat, lit["Prefix"], re.I):
            hits.add(lit["Line"])
    return sorted(hits)


def format_module_refs(lines):
    scan = get_module_scan()
    out = []
    for l in lines[:5]:
        out.append(f"  Module.bsl:{l}: {scan['Lines'][l - 1].strip()}")
    if len(lines) > 5:
        out.append(f"  … и ещё {len(lines) - 5}")
    return "\n".join(out)


# Обработчики удаляемого, которые есть процедурами в модуле, — в отчёт: мёртвый код, решает автор.
def add_left_handlers(handlers):
    scan = get_module_scan()
    if not scan["Exists"]:
        return
    for h in handlers:
        if not h or h.lower() in [x.lower() for x in left_handlers]:
            continue
        pat = rf"^\s*((Асинх|Async)\s+)?(Процедура|Функция|Procedure|Function)\s+{re.escape(h)}\s*\("
        if re.search(pat, scan["Raw"], re.I | re.M):
            left_handlers.append(h)


def test_borrowed(name, kind):
    if not is_extension:
        return False
    bf = root.find("f:BaseForm", NS)
    target = name.lower()
    if kind == 'element':
        cands = [n for n in bf.iterdescendants() if _is_el(n) and n.get("name") is not None]
    elif kind == 'command':
        cands = bf.findall("f:Commands/f:Command", NS)
    else:
        cands = bf.findall("f:Attributes/f:Attribute", NS)
    for n in cands:
        if etree.QName(n.tag).namespace == FORM_NS and (n.get("name") or "").lower() == target:
            if kind != 'element' or local_name(n.getparent()) == 'ChildItems':
                return True
    return False


# Ближайший именованный элемент формы, которому принадлежит узел.
def get_owner_element(node):
    cur = node
    while cur is not None:
        if _is_el(cur) and etree.QName(cur.tag).namespace == FORM_NS and cur.get("name") is not None and \
                (cur.getparent() is not None and local_name(cur.getparent()) == 'ChildItems' or local_name(cur) in COMPANION_TAGS):
            return cur
        cur = cur.getparent()
    return None


def get_element_scopes():
    scopes = []
    if root_ci is not None:
        scopes.append(root_ci)
    acb_node = root.find("f:AutoCommandBar", NS)
    if acb_node is not None:
        scopes.append(acb_node)
    return scopes


def get_named_in_subtree(node):
    names = [node.get("name")]
    for d in node.iterdescendants():
        if _is_el(d) and d.get("name") is not None and etree.QName(d.tag).namespace == FORM_NS and \
                (local_name(d.getparent()) == 'ChildItems' or local_name(d) in COMPANION_TAGS):
            names.append(d.get("name"))
    return names


def _text(t):
    return "".join(t.itertext()).strip()


def _uniq(seq):
    out = []
    for x in seq:
        if x not in out:
            out.append(x)
    return out


def _form_ca():
    return root.find("f:Attributes/f:ConditionalAppearance", NS)


# Общий удалитель элементов: каскад зависимых кнопок и дополнений поиска, отказ при ссылках из
# модуля и из привязанных полей, чистка условного оформления.
def remove_form_elements(roots, ctx, reason):
    global removed_count
    # Вложенные в другие удаляемые — поглощаются
    items = []
    for r in roots:
        if not any(o is not r and is_inside(r, o) for o in roots):
            items.append({"Node": r, "Reason": reason})
    for it in list(items):
        for nm in get_named_in_subtree(it["Node"]):
            if test_borrowed(nm, 'element'):
                fail(f"{ctx}: '{nm}' — заимствованный элемент, платформа не даёт удалять его в расширении; чтобы скрыть — {{\"set\": \"{nm}\", \"visible\": false}}")

    # Каскад: кнопки, дополнения поиска; отказ: прочие привязки Items.X…
    changed = True
    blockers = []
    while changed:
        changed = False
        removed_names = {}
        for it in items:
            for nm in get_named_in_subtree(it["Node"]):
                removed_names[nm.lower()] = nm
        blockers = []
        for s in get_element_scopes():
            for t in s.iterdescendants():
                if not _is_el(t):
                    continue
                ln = local_name(t)
                if not (ln == 'CommandName' or ln == 'CommandSource' or ln.endswith('DataPath') or (ln == 'Item' and local_name(t.getparent()) == 'AdditionSource')):
                    continue
                txt = _text(t)
                target = None
                m = re.match(r'^Form\.Item\.([^.]+)\.', txt, re.I)
                if m:
                    target = m.group(1)
                elif ln == 'CommandSource' and re.match(r'^Item\.([^.]+)$', txt, re.I):
                    target = re.match(r'^Item\.([^.]+)$', txt, re.I).group(1)
                elif re.match(r'^Items\.([^.]+)\.', txt, re.I):
                    target = re.match(r'^Items\.([^.]+)\.', txt, re.I).group(1)
                elif ln == 'Item':
                    target = txt
                if not target or target.lower() not in removed_names:
                    continue
                owner = get_owner_element(t)
                if owner is None:
                    continue
                if any(is_inside(owner, it["Node"]) for it in items):
                    continue
                ol = local_name(owner)
                if ol in ('Button', 'ButtonGroup', 'Popup', 'CommandBar', 'SearchStringAddition', 'ViewStatusAddition', 'SearchControlAddition'):
                    items.append({"Node": owner, "Reason": f"зависел от удалённого {removed_names[target.lower()]}"})
                    changed = True
                    break
                blockers.append(f"{owner.get('name')} ({ol}, {ln} = {txt})")
            if changed:
                break
    if blockers:
        fail(f"{ctx}: на удаляемое ссылаются элементы, которые остаются: {'; '.join(_uniq(blockers))} — удали их в том же remove или перепривяжи")

    # Заимствованное и ссылки из модуля — по всем удаляемым именам
    all_names = []
    for it in items:
        all_names += get_named_in_subtree(it["Node"])
    all_names = _uniq(all_names)
    for nm in all_names:
        if test_borrowed(nm, 'element'):
            fail(f"{ctx}: '{nm}' — заимствованный элемент, платформа не даёт удалять его в расширении; чтобы скрыть — {{\"set\": \"{nm}\", \"visible\": false}}")
    for nm in all_names:
        refs = find_module_refs(nm, 'element')
        if refs:
            fail(f"{ctx}: на элемент '{nm}' ссылается модуль формы — сначала убери обращения из кода:\n{format_module_refs(refs)}")

    # Командный интерфейс формы: пункт с параметром из текущей строки удаляемого — каскадом
    cif = root.find("f:CommandInterface", NS)
    if cif is not None:
        lower_names = {nm.lower() for nm in all_names}
        for a in list(cif.findall(".//f:Item/f:Attribute", NS)):
            m = re.match(r'^~?Items\.([^.]+)(\.|$)', _text(a), re.I)
            if m and m.group(1).lower() in lower_names:
                item = a.getparent()
                parent = item.getparent()
                remove_node_with_ws(item)
                while parent is not root and get_first_element_child(parent) is None:
                    up = parent.getparent()
                    remove_node_with_ws(parent)
                    parent = up
                remove_log.append(f"  - командный интерфейс: пункт с параметром {_text(a)}")

    # Обработчики событий удаляемого
    handlers = []
    for it in items:
        for ev in it["Node"].iter(f"{{{FORM_NS}}}Event"):
            handlers.append(_text(ev))
    add_left_handlers(handlers)

    # Условное оформление: поле удаляемого элемента — из списка оформляемых; пустой список
    # означал бы «вся форма», поэтому такое правило уходит целиком.
    ca = _form_ca()
    if ca is not None:
        lower = {nm.lower() for nm in all_names}
        for rule in list(ca.findall("dcsset:item", NS)):
            sel = rule.find("dcsset:selection", NS)
            if sel is None:
                continue
            hit = False
            for si in list(sel.findall("dcsset:item", NS)):
                f = si.find("dcsset:field", NS)
                if f is not None and _text(f).lower() in lower:
                    remove_log.append(f"  - условное оформление: поле {_text(f)} убрано из правила")
                    remove_node_with_ws(si)
                    hit = True
            if hit and get_first_element_child(sel) is None:
                remove_node_with_ws(rule)
                remove_log.append("  - условное оформление: правило без оформляемых полей удалено")
        if get_first_element_child(ca) is None:
            remove_node_with_ws(ca)

    for it in items:
        node = it["Node"]
        name = node.get("name")
        # вложенные элементы для отчёта — без служебных узлов
        shown = [d.get("name") for d in node.iterdescendants()
                 if _is_el(d) and d.get("name") is not None and etree.QName(d.tag).namespace == FORM_NS and local_name(d.getparent()) == 'ChildItems']
        tail = ""
        if shown:
            lst = ", ".join(shown[:10])
            if len(shown) > 10:
                lst += f", … и ещё {len(shown) - 10}"
            tail = f" (+ {lst})"
        why = f" — {it['Reason']}" if it["Reason"] else ""
        ci = node.getparent()
        holder = ci.getparent()
        remove_node_with_ws(node)
        remove_if_empty_child_items(ci)
        # Опустевшая командная панель или меню — пустым тегом, как пишет платформа
        if holder is not None and local_name(holder) in COMPANION_TAGS and get_first_element_child(holder) is None:
            for c in list(holder):
                holder.remove(c)
            holder.text = None
        remove_log.append(f"  - {name} [{local_name(node)}]{tail}{why}")
        removed_count += 1


def invoke_remove(op, idx):
    ctx = f"elements[{idx}] remove"
    assert_op_keys(op, ['remove'], ctx)
    names = _names_of(op.get("remove"))
    if not names:
        fail(f"{ctx}: укажи имя элемента или список имён")
    nodes = []
    seen = set()
    for n in names:
        if n.lower() in seen:
            fail(f"{ctx}: '{n}' указан дважды")
        seen.add(n.lower())
        node = find_form_element(n)
        if node is None:
            fail(f"{ctx}: элемент '{n}' не найден в форме")
        if local_name(node.getparent()) != 'ChildItems' or local_name(node) in COMPANION_TAGS:
            fail(f"{ctx}: '{n}' — служебный узел ({local_name(node)}) своего элемента, удаляется только вместе с ним")
        nodes.append(node)
    remove_form_elements(nodes, ctx, "")


def remove_form_command(op, idx):
    global removed_count
    ctx = f"commands[{idx}] remove"
    assert_op_keys(op, ['remove'], ctx)
    name = str(op.get("remove"))
    sec = root.find("f:Commands", NS)
    cmd = None
    if sec is not None:
        for c in sec.findall("f:Command", NS):
            if (c.get("name") or "").lower() == name.lower():
                cmd = c
                break
    if cmd is None:
        fail(f"{ctx}: команда '{name}' не найдена в форме")
    name = cmd.get("name")
    if test_borrowed(name, 'command'):
        fail(f"{ctx}: '{name}' — заимствованная команда, платформа не даёт удалять её в расширении")
    refs = find_module_refs(name, 'command')
    if refs:
        fail(f"{ctx}: на команду '{name}' ссылается модуль формы — сначала убери обращения из кода:\n{format_module_refs(refs)}")

    # Кнопки команды — через общий удалитель (их имена тоже проверяются по модулю)
    buttons = []
    for s in get_element_scopes():
        for cn in s.iter(f"{{{FORM_NS}}}CommandName"):
            if _text(cn).lower() == f"form.command.{name}".lower():
                b = get_owner_element(cn)
                if b is not None:
                    buttons.append(b)
    if buttons:
        remove_form_elements(buttons, ctx, f"кнопка удалённой команды {name}")

    # Пункты командного интерфейса формы
    ci = root.find("f:CommandInterface", NS)
    if ci is not None:
        for c in list(ci.findall(".//f:Item/f:Command", NS)):
            if _text(c).lower() != f"form.command.{name}".lower():
                continue
            item = c.getparent()
            parent = item.getparent()
            remove_node_with_ws(item)
            while parent is not root and get_first_element_child(parent) is None:
                up = parent.getparent()
                remove_node_with_ws(parent)
                parent = up
            remove_log.append(f"  - командный интерфейс: пункт команды {name}")

    add_left_handlers([_text(a) for a in cmd.findall("f:Action", NS)])
    remove_node_with_ws(cmd)
    if get_first_element_child(sec) is None:
        remove_node_with_ws(sec)
    remove_log.append(f"  - команда {name}")
    removed_count += 1


def remove_form_attribute(op, idx):
    global removed_count
    ctx = f"attributes[{idx}] remove"
    assert_op_keys(op, ['remove'], ctx)
    name = str(op.get("remove"))
    sec = root.find("f:Attributes", NS)
    attr = None
    if sec is not None:
        for a in sec.findall("f:Attribute", NS):
            if (a.get("name") or "").lower() == name.lower():
                attr = a
                break
    if attr is None:
        fail(f"{ctx}: реквизит '{name}' не найден в форме")
    name = attr.get("name")
    main = attr.find("f:MainAttribute", NS)
    if main is not None and _text(main) == 'true':
        fail(f"{ctx}: '{name}' — основной реквизит формы, он не удаляется")
    if test_borrowed(name, 'attribute'):
        fail(f"{ctx}: '{name}' — заимствованный реквизит, платформа не даёт удалять его в расширении")
    refs = find_module_refs(name, 'attribute')
    if refs:
        fail(f"{ctx}: к реквизиту '{name}' обращается модуль формы — сначала убери обращения из кода:\n{format_module_refs(refs)}")

    # Привязки в форме: пути данных элементов и поля условного оформления
    def is_path(t):
        return t.lower() == name.lower() or t.lower().startswith(name.lower() + ".")

    users = []
    for s in get_element_scopes():
        for t in s.iterdescendants():
            if not _is_el(t) or not local_name(t).endswith('DataPath'):
                continue
            if is_path(_text(t)):
                o = get_owner_element(t)
                if o is not None:
                    users.append(f"{o.get('name')} ({local_name(t)})")
    ca = _form_ca()
    if ca is not None:
        for t in ca.iterdescendants():
            if not _is_el(t) or etree.QName(t.tag).namespace != DCSSET_NS or local_name(t) not in ('left', 'right'):
                continue
            xt = t.get(f"{{{XSI_NS}}}type") or ""
            if xt.endswith(':Field') and is_path(_text(t)):
                users.append(f"условное оформление (отбор по {_text(t)})")
    cif = root.find("f:CommandInterface", NS)
    if cif is not None:
        for a in cif.findall(".//f:Item/f:Attribute", NS):
            at = _text(a).lstrip('~')
            if is_path(at):
                users.append(f"командный интерфейс (параметр {_text(a)})")
    if users:
        fail(f"{ctx}: к реквизиту '{name}' привязаны: {'; '.join(_uniq(users))} — удали или перепривяжи их раньше (elements выполняются до attributes)")
    remove_node_with_ws(attr)
    if get_first_element_child(sec) is None:
        for c in list(sec):
            sec.remove(c)
        sec.text = None
    remove_log.append(f"  - реквизит {name}")
    removed_count += 1


# ── 10. Elements: добавление, перенос, изменение, удаление — по порядку ──

companion_count = 0

elements_list = defn.get("elements") or []
if not isinstance(elements_list, list):
    elements_list = [elements_list]
if elements_list:
    ops = elements_list

    # Вид каждой операции: ключ типа — добавление, move/set — над существующим элементом.
    op_kinds = []
    for i, op in enumerate(ops):
        kinds = []
        if isinstance(op, dict):
            for k in ('move', 'set', 'remove'):
                if k in op:
                    kinds.append(k)
            # Тип элемента XML-именем или по-русски (InputField, ПолеВвода) → канонический ключ
            if not kinds:
                normalize_element_type_synonyms(op)
            # У set ключ типа — свойство (group — ориентация); остальные ключи типа set отвергнет сам.
            if 'set' not in kinds:
                if 'autoCmdBar' in op:
                    kinds.append('autoCmdBar')
                else:
                    for k in ELEMENT_KEYS:
                        if k in op:
                            kinds.append(k)
                            break
        if not kinds:
            fail(f"elements[{i}]: не понять действие — нужен тип элемента (input, group, …), move, set или remove")
        if len(kinds) > 1:
            fail(f"elements[{i}]: одна запись — одно действие, а здесь {' и '.join(kinds)}")
        op_kinds.append(kinds[0])

    # Имена добавляемых элементов уникальны (требование 1С): внутри JSON (рекурсивно по
    # children/columns) и против уже существующих элементов формы.
    def _walk_elem_names(el, seen):
        tk = None
        for key in ELEMENT_KEYS:
            if key in el and el[key] is not None:
                tk = key
                break
        if tk:
            _assert_edit_unique(get_element_name(el, tk), seen, "element name")
        for c in el.get("children", []) or []:
            _walk_elem_names(c, seen)
        for c in el.get("columns", []) or []:
            _walk_elem_names(c, seen)

    dsl_elem_names = set()
    for i, op in enumerate(ops):
        if op_kinds[i] in ('move', 'set', 'remove', 'autoCmdBar'):
            continue
        _walk_elem_names(op, dsl_elem_names)

    start_elem_id = next_elem_id
    for i, op in enumerate(ops):
        if op_kinds[i] == 'move':
            invoke_move(op, i)
        elif op_kinds[i] == 'set':
            invoke_set(op, i)
        elif op_kinds[i] == 'remove':
            invoke_remove(op, i)
        elif op_kinds[i] == 'autoCmdBar':
            invoke_auto_cmd_bar(op, i)
        else:
            invoke_add(op, op_kinds[i], i)
    companion_count = (next_elem_id - start_elem_id) - added_count

# ── 11. Add attributes ──────────────────────────────────────

added_attrs = []

# Удаления (запись с ключом remove) — по порядку, до добавлений
attrs_list = []
_attr_ops = defn.get("attributes") or []
if not isinstance(_attr_ops, list):
    _attr_ops = [_attr_ops]
for _i, _op in enumerate(_attr_ops):
    if isinstance(_op, dict) and "remove" in _op:
        assert_op_keys(_op, ['remove'], f"attributes[{_i}] remove")
        for _rn in _names_of(_op.get("remove")):
            remove_form_attribute({"remove": _rn}, _i)
    else:
        attrs_list.append(_op)
if attrs_list:
    attrs_section = root.find("f:Attributes", NS)
    if attrs_section is None:
        # Секция реквизитов — после ChildItems, Events или AutoCommandBar (как в PS-мастере)
        attrs_section = etree.Element(f"{{{FORM_NS}}}Attributes")
        _after = root_ci
        if _after is None:
            _after = root.find("f:Events", NS)
        if _after is None:
            _after = root.find("f:AutoCommandBar", NS)
        insert_node_at(root, attrs_section, get_next_element_sibling(_after) if _after is not None else None, "\t")

    attr_child_indent = get_child_indent(attrs_section)
    if not attr_child_indent:
        attr_child_indent = "\t\t"

    # Уникальность имён реквизитов: внутри JSON-определения (+ колонки в пределах реквизита) и
    # против уже существующих реквизитов формы.
    dsl_attr_names = set()
    for attr in attrs_list:
        _assert_edit_unique(str(attr["name"]), dsl_attr_names, "attribute name")
        if attr.get("columns"):
            dsl_col_names = set()
            for col in attr["columns"]:
                _assert_edit_unique(str(col["name"]), dsl_col_names, f"column name of '{attr['name']}'")
        if attrs_section.find(f"f:Attribute[@name='{attr['name']}']", NS) is not None:
            print(f"[ERROR] Attribute '{attr['name']}' already exists in form — attribute names must be unique")
            sys.exit(1)

    # Generate attribute fragments
    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for attr in attrs_list:
        attr_id = new_attr_id()
        attr_name = str(attr["name"])
        X(f'{attr_child_indent}<Attribute name="{attr_name}" id="{attr_id}">')
        inner = attr_child_indent + "\t"

        if attr.get("title"):
            emit_mltext(xml_lines, inner, "Title", str(attr["title"]))
        if attr.get("type"):
            emit_type(xml_lines, str(attr["type"]), inner)
        else:
            X(f"{inner}<Type/>")
        if attr.get("main") is True:
            X(f"{inner}<MainAttribute>true</MainAttribute>")
        if attr.get("savedData") is True:
            X(f"{inner}<SavedData>true</SavedData>")
        if attr.get("fillChecking"):
            X(f"{inner}<FillChecking>{attr['fillChecking']}</FillChecking>")

        columns = attr.get("columns")
        if columns and len(columns) > 0:
            X(f"{inner}<Columns>")
            col_id = 1
            for col in columns:
                X(f'{inner}\t<Column name="{col["name"]}" id="{col_id}">')
                if col.get("title"):
                    emit_mltext(xml_lines, inner + "\t\t", "Title", str(col["title"]))
                emit_type(xml_lines, str(col["type"]), inner + "\t\t")
                X(f'{inner}\t</Column>')
                col_id += 1
            X(f"{inner}</Columns>")

        X(f"{attr_child_indent}</Attribute>")
        type_str = str(attr["type"]) if attr.get("type") else "(no type)"
        added_attrs.append(f"  + {attr_name}: {type_str} (id={attr_id})")
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_attrs = import_element_nodes(frag_root)

    for node in imported_attrs:
        insert_into_container(attrs_section, node, None, attr_child_indent)

# ── 12. Add commands ────────────────────────────────────────

added_cmds = []

# Удаления (запись с ключом remove) — по порядку, до добавлений
cmds_list = []
_cmd_ops = defn.get("commands") or []
if not isinstance(_cmd_ops, list):
    _cmd_ops = [_cmd_ops]
for _i, _op in enumerate(_cmd_ops):
    if isinstance(_op, dict) and "remove" in _op:
        assert_op_keys(_op, ['remove'], f"commands[{_i}] remove")
        for _rn in _names_of(_op.get("remove")):
            remove_form_command({"remove": _rn}, _i)
    else:
        cmds_list.append(_op)
if cmds_list:
    cmds_section = root.find("f:Commands", NS)
    if cmds_section is None:
        # Секция команд — после Attributes (порядок платформы: Attributes, Commands, Parameters)
        cmds_section = etree.Element(f"{{{FORM_NS}}}Commands")
        _after = root.find("f:Attributes", NS)
        if _after is None:
            _after = root_ci
        if _after is None:
            _after = root.find("f:Events", NS)
        if _after is None:
            _after = root.find("f:AutoCommandBar", NS)
        insert_node_at(root, cmds_section, get_next_element_sibling(_after) if _after is not None else None, "\t")

    cmd_child_indent = get_child_indent(cmds_section)
    if not cmd_child_indent:
        cmd_child_indent = "\t\t"

    # Уникальность имён команд: внутри JSON-определения и против существующих команд формы.
    dsl_cmd_names = set()
    for cmd in cmds_list:
        _assert_edit_unique(str(cmd["name"]), dsl_cmd_names, "command name")
        if cmds_section.find(f"f:Command[@name='{cmd['name']}']", NS) is not None:
            print(f"[ERROR] Command '{cmd['name']}' already exists in form — command names must be unique")
            sys.exit(1)

    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for cmd in cmds_list:
        cmd_id = new_cmd_id()
        cmd_name = str(cmd["name"])
        X(f'{cmd_child_indent}<Command name="{cmd_name}" id="{cmd_id}">')
        inner = cmd_child_indent + "\t"

        if cmd.get("title"):
            emit_mltext(xml_lines, inner, "Title", str(cmd["title"]))

        if cmd.get("actions"):
            for act in cmd["actions"]:
                act_handler = str(act["handler"])
                call_type_attr = f' callType="{act["callType"]}"' if act.get("callType") else ""
                X(f"{inner}<Action{call_type_attr}>{act_handler}</Action>")
        elif cmd.get("action"):
            call_type_attr = f' callType="{cmd["callType"]}"' if cmd.get("callType") else ""
            X(f"{inner}<Action{call_type_attr}>{cmd['action']}</Action>")

        if cmd.get("shortcut"):
            X(f"{inner}<Shortcut>{cmd['shortcut']}</Shortcut>")
        if cmd.get("picture"):
            X(f"{inner}<Picture>")
            X(f"{inner}\t<xr:Ref>{cmd['picture']}</xr:Ref>")
            X(f"{inner}\t<xr:LoadTransparent>true</xr:LoadTransparent>")
            X(f"{inner}</Picture>")
        if cmd.get("representation"):
            X(f"{inner}<Representation>{cmd['representation']}</Representation>")

        X(f"{cmd_child_indent}</Command>")
        action_str = ""
        if cmd.get("action"):
            action_str = f" -> {cmd['action']}"
        elif cmd.get("actions"):
            action_str = f" -> {len(cmd['actions'])} action(s)"
        added_cmds.append(f"  + {cmd_name}{action_str} (id={cmd_id})")
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_cmds = import_element_nodes(frag_root)

    for node in imported_cmds:
        insert_into_container(cmds_section, node, None, cmd_child_indent)

# ── 12b. Add form-level events ──────────────────────────────

added_form_events = []

form_events_list = defn.get("formEvents") or []
if form_events_list:
    events_section = root.find("f:Events", NS)
    if events_section is None:
        events_section = etree.Element(f"{{{FORM_NS}}}Events")
        # Insert after AutoCommandBar (Events come after AutoCommandBar in 1C)
        acb_node = root.find("f:AutoCommandBar", NS)
        if acb_node is not None:
            acb_idx = list(root).index(acb_node)
            acb_node.tail = (acb_node.tail or "") + "\r\n\t"
            root.insert(acb_idx + 1, events_section)
        else:
            root.append(events_section)

    evt_child_indent = get_child_indent(events_section)
    if not evt_child_indent:
        evt_child_indent = "\t\t"

    xml_lines.clear()
    X(f"<_F {ALL_NS_DECL}>")
    for fe in form_events_list:
        fe_name = str(fe["name"])
        fe_handler = str(fe["handler"])
        call_type_attr = f' callType="{fe["callType"]}"' if fe.get("callType") else ""
        X(f'{evt_child_indent}<Event name="{fe_name}"{call_type_attr}>{fe_handler}</Event>')
        ct_str = f"[{fe['callType']}]" if fe.get("callType") else ""
        added_form_events.append(f"  + {fe_name}{ct_str} -> {fe_handler}")
    X("</_F>")

    frag_text = "\n".join(xml_lines)
    frag_root = parse_fragment(frag_text)
    imported_events = import_element_nodes(frag_root)

    for node in imported_events:
        insert_into_container(events_section, node, None, evt_child_indent)

# ── 12c. Add element-level events ───────────────────────────

added_elem_events = []

elem_events_list = defn.get("elementEvents") or []
if elem_events_list:
    if root_ci is None:
        root_ci = root.find("f:ChildItems", NS)

    for ee in elem_events_list:
        target_name = str(ee["element"])
        target_el = find_element(root_ci, target_name)
        if target_el is None:
            print(f"[WARN] Element '{target_name}' not found -- skipping elementEvent")
            continue

        # Find or create Events element within the target
        target_events = target_el.find("f:Events", NS)
        if target_events is None:
            target_events = etree.SubElement(target_el, f"{{{FORM_NS}}}Events")

        ee_child_indent = get_child_indent(target_events)
        if not ee_child_indent:
            parent_indent = get_child_indent(target_el)
            ee_child_indent = parent_indent + "\t"

        ee_name = str(ee["name"])
        ee_handler = str(ee["handler"])
        call_type_attr = f' callType="{ee["callType"]}"' if ee.get("callType") else ""

        xml_lines.clear()
        X(f"<_F {ALL_NS_DECL}>")
        X(f'{ee_child_indent}<Event name="{ee_name}"{call_type_attr}>{ee_handler}</Event>')
        X("</_F>")

        frag_text = "\n".join(xml_lines)
        frag_root = parse_fragment(frag_text)
        imported_ee = import_element_nodes(frag_root)

        for node in imported_ee:
            insert_into_container(target_events, node, None, ee_child_indent)

        ct_str = f"[{ee['callType']}]" if ee.get("callType") else ""
        added_elem_events.append(f"  + {target_name}.{ee_name}{ct_str} -> {ee_handler}")

# ── 13. Save ────────────────────────────────────────────────

# Round-trip: определить стиль исходного файла (на диске он ещё не перезаписан).
try:
    _fe_raw = open(resolved_form_path, "rb").read()
except OSError:
    _fe_raw = None
if _fe_raw is not None:
    _fe_bom = _fe_raw.startswith(b"\xef\xbb\xbf")
    _fe_body = _fe_raw[3:] if _fe_bom else _fe_raw
    _fe_crlf = b"\r\n" in _fe_body
    _fe_enc_m = re.search(rb'encoding="([^"]+)"', _fe_body[:200])
    _fe_enc = _fe_enc_m.group(1).decode("ascii") if _fe_enc_m else "utf-8"
    _fe_final_nl = _fe_body.endswith(b"\n")
else:
    _fe_bom, _fe_crlf, _fe_enc, _fe_final_nl = True, False, "utf-8", True

xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
# Восстановить регистр encoding как в оригинале.
xml_bytes = xml_bytes.replace(
    b"<?xml version='1.0' encoding='UTF-8'?>",
    b'<?xml version="1.0" encoding="' + _fe_enc.encode("ascii") + b'"?>')
# Канонизировать переносы к LF (убирает &#13; от \r в tail'ах).
xml_bytes = (xml_bytes.replace(b"&#13;\n", b"\n").replace(b"&#13;", b"")
             .replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
# Финальный перенос — как в оригинале.
xml_bytes = xml_bytes.rstrip(b"\n")
if _fe_final_nl:
    xml_bytes += b"\n"
# EOL — как в оригинале.
if _fe_crlf:
    xml_bytes = xml_bytes.replace(b"\n", b"\r\n")
# Write preserving BOM as in original.
with open(resolved_form_path, "wb") as f:
    if _fe_bom:
        f.write(b'\xef\xbb\xbf')
    f.write(xml_bytes)

# ── 14. Summary ─────────────────────────────────────────────

if is_extension:
    print("[EXTENSION] BaseForm detected — IDs start at 1000000+")
    print()

if added_form_events:
    print("Added form events:")
    for line in added_form_events:
        print(line)
    print()

if added_elem_events:
    print("Added element events:")
    for line in added_elem_events:
        print(line)
    print()

if op_log:
    print("Elements:")
    for line in op_log:
        print(line)
    print()

if remove_log:
    print("Removed:")
    for line in remove_log:
        print(line)
    print()

if left_handlers:
    print("Handlers left in module (delete if unused):")
    for h in left_handlers:
        print(f"  {h}")
    print()

if added_attrs:
    print("Added attributes:")
    for line in added_attrs:
        print(line)
    print()

if added_cmds:
    print("Added commands:")
    for line in added_cmds:
        print(line)
    print()

print("---")
total_parts = []
if added_form_events:
    total_parts.append(f"{len(added_form_events)} form event(s)")
if added_elem_events:
    total_parts.append(f"{len(added_elem_events)} element event(s)")
if added_count > 0:
    comp_str = f" (+{companion_count} companions)" if companion_count > 0 else ""
    total_parts.append(f"{added_count} element(s){comp_str}")
if moved_count > 0:
    total_parts.append(f"{moved_count} moved")
if changed_count > 0:
    total_parts.append(f"{changed_count} property change(s)")
if removed_count > 0:
    total_parts.append(f"{removed_count} removed")
if added_attrs:
    total_parts.append(f"{len(added_attrs)} attribute(s)")
if added_cmds:
    total_parts.append(f"{len(added_cmds)} command(s)")
print(f"Total: {', '.join(total_parts)}")
print("Run /form-validate to verify.")
