#!/usr/bin/env node
// Инвариант: правка роли (Rights.xml) и формы (Form.xml) меняет ровно то, что просили, и ничего больше.
// Снапшот-тесты это НЕ ловят: они фиксируют итоговый файл целиком, поэтому лишняя
// перестановка узлов или переписанный соседний блок уехали бы в эталон как норма.
// Здесь считается diff к ИСХОДНОМУ файлу: сколько строк прибавилось и убыло.
//
// Прогоняет операции по очереди на фикстурах роли и формы и сверяет размер правки.
// Оба рантайма. Выход 1 при нарушении. Запуск: node tests/skills/check-minimal-diff.mjs [--runtime python]
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { removePathSync, copyTreeSync } from '../common/fsutil.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const IS_WIN = process.platform === 'win32';
const requested = process.argv.includes('--runtime')
  ? [process.argv[process.argv.indexOf('--runtime') + 1] === 'python' ? 'python' : 'powershell']
  : ['powershell', 'python'];
const runtimes = requested.filter(rt => rt !== 'powershell' || IS_WIN);
if (requested.includes('powershell') && !IS_WIN) {
  console.log(`[powershell] пропущен: PowerShell не исполняется на ${process.platform}`);
}
if (runtimes.length === 0) {
  console.log('Нечего проверять: запрошен только powershell, а он на этой ОС не исполняется.');
  process.exit(1);
}

const PY = process.env.PYTHON || (IS_WIN ? 'python' : 'python3');
const ROLE_FIXTURE = join(ROOT, 'tests', 'skills', 'cases', 'role-edit', 'fixtures', 'role-base');
const RIGHTS = join('Roles', 'Менеджер', 'Ext', 'Rights.xml');

// Ожидаемый размер правки: +добавлено / -убрано строк. Числа — форма узлов Rights.xml:
// <right> это 4 строки, <object> добавляет ещё 3 (открывающий тег, имя, закрывающий),
// ограничение — 3.
const ROLE_STEPS = [
  { op: 'add-rights', value: 'InformationRegister.Цены: Read', plus: 7, minus: 0,
    why: 'новый узел объекта с одним правом: обёртка, имя и четыре строки права' },
  { op: 'add-rights', value: 'InformationRegister.Цены: Update', plus: 4, minus: 0,
    why: 'ещё одно право в существующий узел' },
  { op: 'set-rls', value: 'InformationRegister.Цены.Read: ГДЕ ЛОЖЬ', plus: 3, minus: 0,
    why: 'ограничение на существующем праве' },
  { op: 'remove-rls', value: 'InformationRegister.Цены.Read', plus: 0, minus: 3,
    why: 'снятие ограничения, право остаётся' },
  { op: 'remove-rights', value: 'InformationRegister.Цены: Update', plus: 0, minus: 4,
    why: 'снятие права, узел остаётся' },
];

function skill(runtime, name, args, cwd) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const script = join(ROOT, '.claude', 'skills', name, 'scripts', `${name}${ext}`);
  const cmd = runtime === 'python' ? PY : 'powershell.exe';
  const argv = runtime === 'python'
    ? [script, ...args]
    : ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];
  return execFileSync(cmd, argv, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

// Форма: перенос на той же глубине не меняет ни одной строки (только порядок — мультимножество
// то же), со сменой глубины — пересчитывается отступ ровно у строк переносимого узла; set трогает
// только свой тег. Всё сверх этого — правка вне радиуса.
const FORM_FIXTURE = join(ROOT, 'tests', 'skills', 'cases', 'form-edit', 'fixtures', 'move-form');
const FORM = join('Documents', 'ЗаказТест', 'Forms', 'ФормаДокумента', 'Ext', 'Form.xml');
const FORM_STEPS = [
  { json: { elements: [{ move: 'Приоритет', before: 'Склад' }] }, plus: 0, minus: 0,
    why: 'перестановка на той же глубине — строки те же, меняется порядок' },
  { json: { elements: [{ move: 'Организация', after: 'Контрагент' }] }, plus: 0, minus: 0,
    why: 'в соседнюю группу той же глубины' },
  { json: { elements: [{ move: 'Согласован', into: 'ГруппаПодвал' }] }, plus: 7, minus: 7,
    why: 'со страницы в группу: отступ у 7 строк флажка' },
  { json: { elements: [{ set: 'Ответственный', visible: false }] }, plus: 1, minus: 0,
    why: 'один тег Visible' },
  { json: { elements: [{ set: 'Ответственный', visible: true }] }, plus: 0, minus: 1,
    why: 'значение по умолчанию — тег уходит' },
  { json: { elements: [{ set: 'Контрагент', title: 'Покупатель' }] }, plus: 6, minus: 0,
    why: 'многоязычный заголовок — 6 строк' },
  { json: { elements: [{ set: 'ГруппаПодвал', group: 'vertical' }] }, plus: 1, minus: 1,
    why: 'замена значения Group' },
  { json: { elements: [{ remove: 'Номер' }] }, plus: 0, minus: 5,
    why: 'удаление поля — ровно его 5 строк' },
];

function countDiff(before, after) {
  // Сравниваем мультимножества строк: перестановка узла — тоже правка вне радиуса,
  // и она даст ненулевые plus/minus, как и переписанный блок.
  const tally = new Map();
  for (const line of before.split('\n')) tally.set(line, (tally.get(line) || 0) + 1);
  let plus = 0;
  for (const line of after.split('\n')) {
    const n = tally.get(line) || 0;
    if (n > 0) tally.set(line, n - 1); else plus++;
  }
  let minus = 0;
  for (const n of tally.values()) minus += n;
  return { plus, minus };
}

let failed = 0;
function check(runtime, label, step, before, after) {
  const { plus, minus } = countDiff(before, after);
  const ok = plus === step.plus && minus === step.minus;
  if (!ok) failed++;
  console.log(`  [${runtime}] ${ok ? '+' : 'x'} ${label}: +${plus}/-${minus} строк ` +
    `(ожидалось +${step.plus}/-${step.minus} — ${step.why})`);
}

for (const runtime of runtimes) {
  const work = mkdtempSync(join(tmpdir(), 'mindiff-'));
  try {
    copyTreeSync(ROLE_FIXTURE, work);
    for (const step of ROLE_STEPS) {
      const before = readFileSync(join(work, RIGHTS), 'utf8');
      skill(runtime, 'role-edit', ['-RolePath', join(work, 'Roles', 'Менеджер'), '-Operation', step.op,
        '-Value', step.value, '-NoValidate'], work);
      check(runtime, step.op, step, before, readFileSync(join(work, RIGHTS), 'utf8'));
    }
  } finally {
    removePathSync(work);
  }
  const fwork = mkdtempSync(join(tmpdir(), 'mindiff-'));
  try {
    copyTreeSync(FORM_FIXTURE, fwork);
    const jsonPath = join(fwork, 'op.json');
    for (const step of FORM_STEPS) {
      const before = readFileSync(join(fwork, FORM), 'utf8');
      writeFileSync(jsonPath, JSON.stringify(step.json), 'utf8');
      skill(runtime, 'form-edit', ['-FormPath', join(fwork, FORM), '-JsonPath', jsonPath], fwork);
      const e = step.json.elements[0];
      check(runtime, e.move ? `move ${e.move}` : e.set ? `set ${e.set}` : `remove ${e.remove}`, step, before, readFileSync(join(fwork, FORM), 'utf8'));
    }
  } finally {
    removePathSync(fwork);
  }
}

if (failed) {
  console.log(`\n${failed} НАРУШЕНИЙ: правка задела больше, чем просили.`);
  process.exit(1);
}
console.log('\nOK — правка роли и формы меняет только то, что просили.');
