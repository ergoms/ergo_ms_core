import { readdir, mkdir, readFile, copyFile, unlink } from 'fs/promises';
import { join, dirname } from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { existsSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const projectRoot = join(__dirname, '..');
const extensionsDir = join(projectRoot, 'extensions');
const localExtensionsDir = join(projectRoot, 'local-extensions');

/**
 * Обновить VSIX файлы из исходных расширений
 */
async function updateVsixFiles() {
  try {
    // Проверяем наличие директории расширений
    if (!existsSync(extensionsDir)) {
      console.log('❌ Директория расширений не найдена:', extensionsDir);
      return;
    }

    // Создаем директорию для VSIX файлов, если её нет
    if (!existsSync(localExtensionsDir)) {
      await mkdir(localExtensionsDir, { recursive: true });
    }

    // Получаем список расширений
    const extensions = await readdir(extensionsDir, { withFileTypes: true });
    const extensionDirs = extensions
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name);

    if (extensionDirs.length === 0) {
      console.log('❌ Расширения не найдены в директории:', extensionsDir);
      return;
    }

    console.log(`📦 Найдено ${extensionDirs.length} расширений для обновления:`);

    for (const extensionName of extensionDirs) {
      const extensionPath = join(extensionsDir, extensionName);
      const packageJsonPath = join(extensionPath, 'package.json');

      // Проверяем наличие package.json
      if (!existsSync(packageJsonPath)) {
        console.log(`⚠️  Пропущено ${extensionName}: package.json не найден`);
        continue;
      }

      try {
        // Читаем package.json для получения имени и версии
        const packageJsonContent = await readFile(packageJsonPath, 'utf-8');
        const packageJson = JSON.parse(packageJsonContent);
        const { name, version, publisher } = packageJson;

        if (!name || !version) {
          console.log(`⚠️  Пропущено ${extensionName}: отсутствуют name или version в package.json`);
          continue;
        }

        const vsixFileName = `${name}-${version}.vsix`;
        const vsixOutputPath = join(localExtensionsDir, vsixFileName);

        console.log(`\n🔧 Обновление VSIX: ${vsixFileName} (${name} v${version})`);

        const osAbstractionPath = join(projectRoot, 'lib', 'os-abstraction.cjs');
        if (existsSync(osAbstractionPath)) {
          const extLibDir = join(extensionPath, 'lib');
          await mkdir(extLibDir, { recursive: true });
          await copyFile(osAbstractionPath, join(extLibDir, 'os-abstraction.cjs'));
        }

        // Упаковываем расширение в VSIX
        execSync(
          `npx --yes @vscode/vsce package --out "${localExtensionsDir}" --allow-missing-repository`,
          {
            stdio: 'inherit',
            cwd: extensionPath,
            shell: true
          }
        );

        // Удаляем устаревшие VSIX того же расширения (иначе install ставит старую версию первой).
        if (existsSync(localExtensionsDir)) {
          const stale = (await readdir(localExtensionsDir)).filter((file) => {
            if (!file.endsWith('.vsix') || file === vsixFileName) {
              return false;
            }
            return file.startsWith(`${name}-`) && /-\d+\.\d+\.\d+\.vsix$/i.test(file);
          });
          for (const file of stale) {
            await unlink(join(localExtensionsDir, file));
            console.log(`  [OK] Удалён устаревший VSIX: ${file}`);
          }
        }

        console.log(`✅ Успешно обновлено: ${vsixFileName}`);
      } catch (error) {
        console.error(`❌ Ошибка при обновлении ${extensionName}:`, error.message);
      }
    }

    console.log('\n✨ Обновление VSIX файлов завершено!');
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.error('❌ Директория расширений не найдена');
    } else {
      console.error('❌ Ошибка:', error.message);
    }
    process.exit(1);
  }
}

updateVsixFiles();

