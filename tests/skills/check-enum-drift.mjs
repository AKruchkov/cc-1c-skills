#!/usr/bin/env node
// Анти-дрейф enum-allowlist-ов: сверяет продублированные списки допустимых значений перечислений
// meta-compile (АВТОРИТЕТ) ↔ meta-validate ↔ meta-edit, а также cf-validate (АВТОРИТЕТ) ↔ cfe-validate. Навыки автономны (allowlist-ы копируются
// намеренно), поэтому нужен гард от расхождений значений (напр. HierarchyItemsOnly vs HierarchyOfItems).
// Парсит .ps1 (канонический порт). Выход 1 при дрейфе. Запуск: node tests/skills/check-enum-drift.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Извлечь PS1-хэштейбл по имени переменной, распарсить "Prop" = @("v1","v2", ...)
function parsePs1EnumMap(file, varName) {
  const text = readFileSync(join(ROOT, file), 'utf8');
  const at = text.indexOf(varName);
  if (at < 0) throw new Error(`${varName} not found in ${file}`);
  let i = text.indexOf('@{', at) + 2, depth = 1, end = i;
  while (i < text.length && depth > 0) {
    const c = text[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
    i++;
  }
  const block = text.slice(text.indexOf('@{', at) + 2, end);
  const map = {};
  // Ключ — свойство или уточнение по виду объекта «Вид.Свойство» (Task.DefaultPresentation)
  const re = /"([\wА-Яа-яЁё.]+)"\s*=\s*@\(([^)]*)\)/g;
  let m;
  while ((m = re.exec(block)) !== null) {
    map[m[1]] = [...m[2].matchAll(/"([^"]*)"/g)].map(v => v[1]);
  }
  return map;
}

const compile  = parsePs1EnumMap('.claude/skills/meta-compile/scripts/meta-compile.ps1', '$script:validEnumValues');
const validate = parsePs1EnumMap('.claude/skills/meta-validate/scripts/meta-validate.ps1', '$validPropertyValues');
const edit     = parsePs1EnumMap('.claude/skills/meta-edit/scripts/meta-edit.ps1', '$script:validEnumValues');

const eq = (a, b) => a.length === b.length && [...a].sort().join('|') === [...b].sort().join('|');

let drift = 0;
for (const [name, map] of [['meta-validate', validate], ['meta-edit', edit]]) {
  for (const prop of Object.keys(map)) {
    if (compile[prop] && !eq(map[prop], compile[prop])) {
      console.log(`DRIFT  ${name}.${prop}: [${map[prop].join(', ')}]  !=  meta-compile [${compile[prop].join(', ')}]`);
      drift++;
    }
  }
}
// meta-edit нормализует те же свойства, что и meta-compile (Normalize-EnumValue — общая копия):
// ключ, которого в meta-edit нет, там молча не проверяется — и алиас подставляется вслепую.
for (const prop of Object.keys(compile)) {
  if (!edit[prop]) {
    console.log(`MISSING meta-edit.${prop}: есть в meta-compile, нет в meta-edit — значение там не проверяется`);
    drift++;
  }
}
// Информационно: свойства в валидаторе/редакторе, которых НЕТ в авторитете (возможен опечатка-ключ или устаревшее)
for (const [name, map] of [['meta-validate', validate], ['meta-edit', edit]]) {
  for (const prop of Object.keys(map)) {
    if (!compile[prop]) console.log(`INFO   ${name}.${prop} нет в meta-compile.validEnumValues (проверьте ключ)`);
  }
}
// Корень конфигурации и корень расширения: общие свойства (режимы совместимости, интерфейс)
// cf-validate и cfe-validate обязаны принимать одинаково — это одни и те же перечисления платформы.
const cfv  = parsePs1EnumMap('.claude/skills/cf-validate/scripts/cf-validate.ps1', '$validEnumValues');
const cfev = parsePs1EnumMap('.claude/skills/cfe-validate/scripts/cfe-validate.ps1', '$validEnumValues');
for (const prop of Object.keys(cfev)) {
  if (cfv[prop] && !eq(cfev[prop], cfv[prop])) {
    console.log(`DRIFT  cfe-validate.${prop}: [${cfev[prop].join(', ')}]  !=  cf-validate [${cfv[prop].join(', ')}]`);
    drift++;
  }
}
// Формы: перечисления свойств элементов и корня — эталон form-compile (генерирует
// debug/form-dsl-revision/gen_enum_table.py); копии — form-edit (общий блок эмиттера) и form-validate.
// Синонимы и порядок дочерних тегов — сверка блока целиком (другой формат записи).
function ps1Block(file, start) {
  const text = readFileSync(join(ROOT, file), 'utf8').replace(/^﻿/, '').replace(/\r\n/g, '\n');
  const at = text.indexOf(start);
  if (at < 0) throw new Error(`${start} not found in ${file}`);
  let i = text.indexOf('@{', at) + 2, depth = 1;
  while (i < text.length && depth > 0) { if (text[i] === '{') depth++; else if (text[i] === '}') depth--; i++; }
  return text.slice(at, i);
}
const FORM_AUTH = '.claude/skills/form-compile/scripts/form-compile.ps1';
const FORM_COPIES = ['.claude/skills/form-edit/scripts/form-edit.ps1', '.claude/skills/form-validate/scripts/form-validate.ps1'];
const formAuth = parsePs1EnumMap(FORM_AUTH, '$script:validEnumValues = @{');
for (const f of FORM_COPIES) {
  const copy = parsePs1EnumMap(f, '$script:validEnumValues = @{');
  const name = f.split('/')[2];
  for (const k of new Set([...Object.keys(formAuth), ...Object.keys(copy)])) {
    if (!copy[k] || !formAuth[k] || !eq(copy[k], formAuth[k])) {
      console.log(`DRIFT  ${name}.validEnumValues[${k}]: [${(copy[k] || []).join(', ')}]  !=  form-compile [${(formAuth[k] || []).join(', ')}]`);
      drift++;
    }
  }
  for (const v of ['$script:enumValueAliases = @{', '$script:childTagOrder = @{']) {
    if (ps1Block(f, v) !== ps1Block(FORM_AUTH, v)) {
      console.log(`DRIFT  ${name}: ${v.split(' ')[0]} отличается от form-compile`);
      drift++;
    }
  }
}
// py-копии тех же таблиц: блок от присваивания до закрывающей скобки в первой колонке
function pyBlock(file, start) {
  const text = readFileSync(join(ROOT, file), 'utf8').replace(/\r\n/g, '\n');
  const at = text.indexOf(start);
  if (at < 0) throw new Error(`${start} not found in ${file}`);
  return text.slice(at, text.indexOf('\n}', at) + 2);
}
const FORM_AUTH_PY = '.claude/skills/form-compile/scripts/form-compile.py';
for (const f of ['.claude/skills/form-edit/scripts/form-edit.py', '.claude/skills/form-validate/scripts/form-validate.py']) {
  for (const v of ['valid_enum_values = {', 'enum_value_aliases = {', 'CHILD_TAG_ORDER = {']) {
    if (pyBlock(f, v) !== pyBlock(FORM_AUTH_PY, v)) {
      console.log(`DRIFT  ${f.split('/')[2]} (py): ${v.split(' ')[0]} отличается от form-compile.py`);
      drift++;
    }
  }
}
console.log(drift === 0 ? 'OK — нет дрейфа значений enum-allowlist (meta-* vs meta-compile, cfe-validate vs cf-validate, form-edit/form-validate vs form-compile)' : `\n${drift} DRIFT(s) — свести к эталону.`);
process.exit(drift ? 1 : 0);
