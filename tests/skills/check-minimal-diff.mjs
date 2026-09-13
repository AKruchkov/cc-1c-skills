#!/usr/bin/env node
// Инвариант: правка роли меняет в Rights.xml ровно то, что просили, и ничего больше.
// Снапшот-тесты это НЕ ловят: они фиксируют итоговый файл целиком, поэтому лишняя
// перестановка узлов или переписанный соседний блок уехали бы в эталон как норма.
// Здесь считается diff к ИСХОДНОМУ файлу: сколько строк прибавилось и убыло.
//
// Прогоняет операции по очереди на фикстуре роли и сверяет размер правки.
// Оба рантайма. Выход 1 при нарушении. Запуск: node tests/skills/check-minimal-diff.mjs [--runtime python]
import { execFileSync } from 'node:child_process';
import { readFileSync, mkdtempSync } from 'node:fs';
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
const FIXTURE = join(ROOT, 'tests', 'skills', 'cases', 'role-edit', 'fixtures', 'role-base');
const RIGHTS = join('Roles', 'Менеджер', 'Ext', 'Rights.xml');

// Ожидаемый размер правки: +добавлено / -убрано строк. Числа — форма узлов Rights.xml:
// <right> это 4 строки, <object> добавляет ещё 3 (открывающий тег, имя, закрывающий),
// ограничение — 3.
const STEPS = [
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

function skill(runtime, args, cwd) {
  const ext = runtime === 'python' ? '.py' : '.ps1';
  const script = join(ROOT, '.claude', 'skills', 'role-edit', 'scripts', `role-edit${ext}`);
  const cmd = runtime === 'python' ? PY : 'powershell.exe';
  const argv = runtime === 'python'
    ? [script, ...args]
    : ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, ...args];
  return execFileSync(cmd, argv, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

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
for (const runtime of runtimes) {
  const work = mkdtempSync(join(tmpdir(), 'mindiff-'));
  try {
    copyTreeSync(FIXTURE, work);
    for (const step of STEPS) {
      const before = readFileSync(join(work, RIGHTS), 'utf8');
      skill(runtime, ['-RolePath', join(work, 'Roles', 'Менеджер'), '-Operation', step.op,
        '-Value', step.value, '-NoValidate'], work);
      const after = readFileSync(join(work, RIGHTS), 'utf8');
      const { plus, minus } = countDiff(before, after);
      const ok = plus === step.plus && minus === step.minus;
      if (!ok) failed++;
      console.log(`  [${runtime}] ${ok ? '+' : 'x'} ${step.op}: +${plus}/-${minus} строк ` +
        `(ожидалось +${step.plus}/-${step.minus} — ${step.why})`);
    }
  } finally {
    removePathSync(work);
  }
}

if (failed) {
  console.log(`\n${failed} НАРУШЕНИЙ: правка задела больше, чем просили.`);
  process.exit(1);
}
console.log('\nOK — правка роли меняет только то, что просили.');
