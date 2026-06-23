import { readdir as readdirAsync, mkdir, rm, readFile, copyFile } from 'fs/promises';
import { join, dirname } from 'path';
import { execSync } from 'child_process';
import { existsSync } from 'fs';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const osAbstraction = require('./os-abstraction.cjs');

const DEP0169_FLAG = '--disable-warning=DEP0169';

export function buildCodeCliEnv(baseEnv = process.env) {
  const nodeOptions = [baseEnv.NODE_OPTIONS, DEP0169_FLAG].filter(Boolean).join(' ').trim();
  return { ...baseEnv, NODE_OPTIONS: nodeOptions };
}

export function runCodeCli(command, options = {}) {
  const { cwd, stdio = 'inherit' } = options;
  execSync(command, {
    stdio,
    cwd,
    shell: true,
    env: buildCodeCliEnv(),
  });
}

export function getExtensionInstallDirs(homeDir) {
  const dirs = [
    osAbstraction.getLocalExtensionsDir(homeDir, false),
    osAbstraction.getLocalExtensionsDir(homeDir, true),
  ];

  for (const remoteDir of osAbstraction.getRemoteExtensionsDirs(homeDir)) {
    dirs.push(remoteDir);
  }

  return dirs;
}

export async function extractVsix(vsixPath, extractDir) {
  await mkdir(extractDir, { recursive: true });

  if (osAbstraction.isWindows()) {
    const zipPath = join(dirname(extractDir), `${basenameWithoutExt(vsixPath)}.zip`);
    await copyFile(vsixPath, zipPath);
    const escapedZip = zipPath.replace(/'/g, "''");
    const escapedDir = extractDir.replace(/'/g, "''");
    try {
      execSync(
        `powershell -NoProfile -Command "Expand-Archive -LiteralPath '${escapedZip}' -DestinationPath '${escapedDir}' -Force"`,
        { stdio: 'pipe' },
      );
    } finally {
      await rm(zipPath, { force: true }).catch(() => {});
    }
  } else {
    execSync(`unzip -o -q "${vsixPath}" -d "${extractDir}"`, { stdio: 'pipe' });
  }

  return join(extractDir, 'extension');
}

function basenameWithoutExt(filePath) {
  const fileName = filePath.split(/[/\\]/).pop();
  return fileName.replace(/\.[^.]+$/, '');
}

export async function copyDirectory(sourceDir, targetDir) {
  await mkdir(targetDir, { recursive: true });
  const entries = await readdirAsync(sourceDir, { withFileTypes: true });

  for (const entry of entries) {
    const sourcePath = join(sourceDir, entry.name);
    const targetPath = join(targetDir, entry.name);

    if (entry.isDirectory()) {
      await copyDirectory(sourcePath, targetPath);
    } else {
      await copyFile(sourcePath, targetPath);
    }
  }
}

export async function readVsixPackageJson(vsixPath, tempRoot) {
  const extensionId = vsixPath.split(/[/\\]/).pop().replace(/\.vsix$/, '');
  const tempDir = join(tempRoot, extensionId);

  if (existsSync(tempDir)) {
    await rm(tempDir, { recursive: true, force: true });
  }

  const extractedDir = await extractVsix(vsixPath, tempDir);
  const packageJsonPath = join(extractedDir, 'package.json');

  if (!existsSync(packageJsonPath)) {
    await rm(tempDir, { recursive: true, force: true }).catch(() => {});
    return null;
  }

  const packageJson = JSON.parse(await readFile(packageJsonPath, 'utf-8'));
  await rm(tempDir, { recursive: true, force: true }).catch(() => {});

  return packageJson;
}

export async function installExtensionFromVsix(vsixPath, homeDir, tempRoot) {
  const extensionId = vsixPath.split(/[/\\]/).pop().replace(/\.vsix$/, '');
  const tempDir = join(tempRoot, extensionId);

  if (existsSync(tempDir)) {
    await rm(tempDir, { recursive: true, force: true });
  }

  const extractedDir = await extractVsix(vsixPath, tempDir);
  const packageJsonPath = join(extractedDir, 'package.json');

  if (!existsSync(packageJsonPath)) {
    await rm(tempDir, { recursive: true, force: true }).catch(() => {});
    return false;
  }

  const packageJson = JSON.parse(await readFile(packageJsonPath, 'utf-8'));
  const { publisher, name, version } = packageJson;

  if (!publisher || !name || !version) {
    await rm(tempDir, { recursive: true, force: true }).catch(() => {});
    return false;
  }

  const extensionDirName = `${publisher}.${name}-${version}`;
  let installed = false;

  for (const installDir of getExtensionInstallDirs(homeDir)) {
    try {
      await mkdir(installDir, { recursive: true });
      const targetDir = join(installDir, extensionDirName);

      if (existsSync(targetDir)) {
        await rm(targetDir, { recursive: true, force: true });
      }

      await copyDirectory(extractedDir, targetDir);
      installed = true;
    } catch {
      // Директория может быть недоступна на текущем хосте.
    }
  }

  await rm(tempDir, { recursive: true, force: true }).catch(() => {});
  return installed;
}

export async function uninstallExtensionFromDirs(vsixPath, homeDir, tempRoot) {
  const packageJson = await readVsixPackageJson(vsixPath, tempRoot);
  if (!packageJson) {
    return false;
  }

  const { publisher, name, version } = packageJson;
  if (!publisher || !name || !version) {
    return false;
  }

  const extensionDirName = `${publisher}.${name}-${version}`;
  let removed = false;

  for (const installDir of getExtensionInstallDirs(homeDir)) {
    const targetDir = join(installDir, extensionDirName);
    if (!existsSync(targetDir)) {
      continue;
    }

    try {
      await rm(targetDir, { recursive: true, force: true });
      removed = true;
    } catch {
      // Пропускаем недоступные директории.
    }
  }

  return removed;
}
