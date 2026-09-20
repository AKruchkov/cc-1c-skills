#!/usr/bin/env node
// Раундтрип имён типов: всё, что ПЕЧАТАЕТ meta-info, обязан ПРИНИМАТЬ meta-compile (АВТОРИТЕТ).
//
// Зачем гард. meta-info — читающий навык, и его вывод модель подаёт обратно на вход компилятора.
// До этой проверки связь держалась на честном слове и рвалась молча в обе стороны:
//   * meta-info печатал «ДокументОбъект.Заказ» в источниках подписки, а meta-compile отвечал
//     «Неизвестный тип» — не были заведены синонимы русских объектных имён (33 метки из 41);
//   * в карте meta-info не было ConstantValueManager и ChartOfCalculationTypesObject, хотя
//     meta-compile их эмитит, — и типы печатались по-английски посреди русского вывода.
// Ни один снэпшот этого не видел: кейсы читают и компилируют по отдельности, круг не замыкая.
//
// Инвариант СТРОГИЙ в одну сторону: для каждой метки, которую умеет печатать meta-info, в словаре
// meta-compile должен быть ключ (метка в нижнем регистре), ведущий РОВНО в тот же канон. Обратное
// неверно намеренно: компилятор знает формы, которых читалка не печатает (английские, полные
// варианты рядом с аббревиатурами).
//
// Плюс проверяем, что карты не разошлись между портами навыка: значения переводов — часть вывода,
// а расхождение портов дало бы разный текст на один и тот же файл.
//
// Парсит .ps1 как канон, .py как копию. Выход 1 при расхождении.
// Запуск: node tests/skills/check-typeset-coverage.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (f) => readFileSync(join(ROOT, f), 'utf8');

// Метки, зашитые прямо в Format-SingleTypeSet / Format-SingleType, а не в карту.
const INLINE_LABELS = {
  Characteristic: 'Характеристика',
  DefinedType: 'ОпределяемыйТип',
  AnyRef: 'ЛюбаяСсылка',
  AnyIBRef: 'ЛюбаяСсылкаИБ',
};

// $objectTypeMap = @{ "CatalogObject"="СправочникОбъект"; … } — записи в одну или несколько строк.
function parsePs1Map(text, name) {
  const m = new RegExp(`\\$${name} = @\\{([\\s\\S]*?)\\n\\}`).exec(text);
  if (!m) throw new Error(`карта $${name} не найдена в .ps1 — реестр протух`);
  const map = new Map();
  const re = /"([A-Za-z]+)"\s*=\s*"([^"]+)"/g;
  let e;
  while ((e = re.exec(m[1])) !== null) map.set(e[1], e[2]);
  if (map.size === 0) throw new Error(`карта $${name} пуста — реестр протух`);
  return map;
}

// object_type_map = { "CatalogObject": "СправочникОбъект", … }
function parsePyMap(text, name) {
  const m = new RegExp(`^${name} = \\{([\\s\\S]*?)^\\}`, 'm').exec(text);
  if (!m) throw new Error(`карта ${name} не найдена в .py — реестр протух`);
  const map = new Map();
  const re = /"([A-Za-z]+)"\s*:\s*"([^"]+)"/g;
  let e;
  while ((e = re.exec(m[1])) !== null) map.set(e[1], e[2]);
  if (map.size === 0) throw new Error(`карта ${name} пуста — реестр протух`);
  return map;
}

function parseSynonyms(text) {
  const map = new Map();
  const re = /\$script:typeSynonyms\["([^"]+)"\]\s*=\s*"([^"]*)"/g;
  let m;
  while ((m = re.exec(text)) !== null) map.set(m[1], m[2]);
  if (map.size === 0) throw new Error('словарь typeSynonyms не найден в meta-compile — реестр протух');
  return map;
}

const infoPs1 = read('.claude/skills/meta-info/scripts/meta-info.ps1');
const infoPy = read('.claude/skills/meta-info/scripts/meta-info.py');
const synonyms = parseSynonyms(read('.claude/skills/meta-compile/scripts/meta-compile.ps1'));

let drift = 0;

// ── 1. Порты навыка-читалки не разошлись ────────────────────────────────────
for (const [ps1Name, pyName] of [['objectTypeMap', 'object_type_map'], ['refTypeMap', 'ref_type_map']]) {
  const a = parsePs1Map(infoPs1, ps1Name);
  const b = parsePyMap(infoPy, pyName);
  for (const [k, v] of a) {
    if (!b.has(k)) { console.log(`DRIFT  ${pyName}: нет ключа "${k}" (в .ps1 = "${v}")`); drift++; }
    else if (b.get(k) !== v) { console.log(`DRIFT  ${pyName}."${k}" = "${b.get(k)}"  !=  .ps1 "${v}"`); drift++; }
  }
  for (const k of b.keys()) {
    if (!a.has(k)) { console.log(`DRIFT  ${ps1Name}: нет ключа "${k}", который есть в .py`); drift++; }
  }
  console.log(`  ${ps1Name}: ${a.size} меток, порты совпадают`);
}

// ── 2. Каждая метка читалки принимается компилятором ────────────────────────
const labels = new Map([
  ...parsePs1Map(infoPs1, 'objectTypeMap'),
  ...parsePs1Map(infoPs1, 'refTypeMap'),
  ...Object.entries(INLINE_LABELS),
]);

for (const [canon, label] of [...labels].sort((x, y) => x[1].localeCompare(y[1]))) {
  const key = label.toLowerCase();
  if (!synonyms.has(key)) {
    console.log(`DRIFT  meta-info печатает "${label}", а meta-compile его не знает (ждётся synonyms["${key}"] = "${canon}")`);
    drift++;
  } else if (synonyms.get(key) !== canon) {
    console.log(`DRIFT  synonyms["${key}"] = "${synonyms.get(key)}", а meta-info печатает это как "${canon}"`);
    drift++;
  }
}
if (drift === 0) console.log(`  меток читалки: ${labels.size}, все приняты компилятором`);

console.log(drift === 0
  ? `OK — вывод meta-info замыкается на вход meta-compile (${labels.size} меток)`
  : `\n${drift} DRIFT(s) — завести метку в словарь meta-compile или убрать из карты meta-info.`);
process.exit(drift ? 1 : 0);
