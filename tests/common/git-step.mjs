// Шаг preRun `git` — общий для runner.mjs и verify-snapshots.mjs, чтобы оба раннера строили
// одинаковый репозиторий. Настройки машины не влияют: автор коммита задан, перевод строк и
// подпись коммитов выключены.
import { execFileSync } from 'child_process';

const GIT_STEP_CONFIG = [
  '-c', 'user.name=test', '-c', 'user.email=test@example.com',
  '-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false',
  '-c', 'commit.gpgsign=false', '-c', 'init.defaultBranch=main',
];

export function runGitStep(workDir, args) {
  execFileSync('git', [...GIT_STEP_CONFIG, ...args], { cwd: workDir, stdio: 'pipe' });
}
