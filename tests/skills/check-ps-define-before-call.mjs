#!/usr/bin/env node
// PowerShell ищет функцию в момент ВЫЗОВА и видит только те определения, которые к этому
// моменту уже выполнились. Объявление ниже точки вызова отказывает молчаливо-наполовину:
// CommandNotFoundException уходит в stderr, вызывающая функция получает $null и спокойно
// идёт по ветке «не нашли». Так per-database v8path оказался no-op сразу в трёх навыках
// (#93) — тесты этого не заметили, потому что откат на корневой v8path выглядит штатно.
//
// В .py-порте такого класса ошибок нет: Python связывает имя при вызове, порядок определений
// в модуле не важен. Поэтому гард только для .ps1 — и поэтому расхождение портов молчаливое.
//
// Что проверяем: для каждой функции из списка — если навык её вызывает на верхнем уровне
// (или из функции, которая вызывается на верхнем уровне), определение обязано стоять выше
// первой строки, где начинается цепочка.
//
// Запуск: node tests/skills/check-ps-define-before-call.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');

// Цепочка выбора платформы: кто кого зовёт. Точка входа вызывается с верхнего уровня.
const CHAINS = [
  {
    entry: 'Find-ProjectV8Path',
    // вызов точки входа на верхнем уровне скрипта
    entryCall: /^\s*\$V8Path\s*=\s*Find-ProjectV8Path\s*$/,
    callees: ['Find-ProjectDatabase', 'Test-SamePath', 'Find-V8Project'],
  },
];

const errors = [];
let checked = 0;

for (const skill of readdirSync(SKILLS)) {
  const scriptsDir = join(SKILLS, skill, 'scripts');
  if (!existsSync(scriptsDir)) continue;
  for (const file of readdirSync(scriptsDir)) {
    if (!file.endsWith('.ps1')) continue;
    const path = join(scriptsDir, file);
    const lines = readFileSync(path, 'utf8').split('\n');

    for (const chain of CHAINS) {
      const callLine = lines.findIndex(l => chain.entryCall.test(l));
      if (callLine < 0) continue;
      checked++;
      const defLine = name => lines.findIndex(l => l.trimStart().startsWith(`function ${name}`));
      for (const name of [chain.entry, ...chain.callees]) {
        const def = defLine(name);
        if (def < 0) {
          errors.push(`${skill}/${file}: ${chain.entry} зовёт ${name}, но в навыке её нет`);
          continue;
        }
        if (def > callLine) {
          errors.push(`${skill}/${file}: function ${name} объявлена на строке ${def + 1}, `
            + `а цепочка ${chain.entry} выполняется на строке ${callLine + 1} — `
            + `PowerShell её не увидит (отказ уйдёт в stderr, результат станет $null)`);
        }
      }
    }
  }
}

if (errors.length) {
  console.log(`${errors.length} РАСХОЖДЕНИЙ:`);
  for (const e of errors) console.log(`  [ERROR] ${e}`);
  console.log('\nПоднимите определения выше точки вызова — порядок в .ps1 значим.');
  process.exit(1);
}

console.log(`Проверено цепочек: ${checked}`);
console.log('OK — все функции объявлены выше точки вызова.');
