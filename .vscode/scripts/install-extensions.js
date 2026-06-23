import { readdir, mkdir, rm } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import os from 'os';
import { existsSync } from 'fs';
import {
  copyDirectory,
  installExtensionFromVsix,
  runCodeCli,
} from '../lib/extension-cli.js';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const osAbstraction = require('../lib/os-abstraction.cjs');

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const projectRoot = join(__dirname, '..');
const extensionsDir = join(projectRoot, 'local-extensions');
const tempRoot = join(projectRoot, '.temp-extract');

async function installUserConfigToRemote() {
  if (!osAbstraction.supportsRemoteInstall()) {
    return false;
  }

  try {
    const sourceExtensionDir = join(projectRoot, 'extensions', 'user-config');
    if (!existsSync(sourceExtensionDir)) {
      console.log('  ℹ️  Исходная директория расширения не найдена, пропускаем установку на удаленный сервер');
      return false;
    }

    const remoteDirs = osAbstraction.getRemoteExtensionsDirs(os.homedir());
    if (remoteDirs.length === 0) {
      return false;
    }

    let installed = false;
    const extensionName = 'ergo-ms-user-config-1.2.0';

    for (const remoteDir of remoteDirs) {
      try {
        await mkdir(remoteDir, { recursive: true });
        const targetDir = join(remoteDir, extensionName);

        if (existsSync(targetDir)) {
          await rm(targetDir, { recursive: true, force: true });
        }

        await copyDirectory(sourceExtensionDir, targetDir);
        console.log(`  ✅ Установлено на удаленный сервер: ${remoteDir}`);
        installed = true;
      } catch {
        console.log(`  ℹ️  Директория недоступна: ${remoteDir}`);
      }
    }

    return installed;
  } catch (error) {
    console.error(`  ⚠️  Ошибка при установке на удаленный сервер: ${error.message}`);
    return false;
  }
}

async function installExtensions() {
  try {
    const files = await readdir(extensionsDir);
    const vsixFiles = files.filter(file => file.endsWith('.vsix'));

    if (vsixFiles.length === 0) {
      console.log('❌ VSIX файлы не найдены в папке local-extensions');
      return;
    }

    const isRemote = process.env.SSH_CONNECTION || process.env.SSH_CLIENT ||
      existsSync(join(os.homedir(), '.vscode-server')) ||
      existsSync(join(os.homedir(), '.cursor-server'));

    if (isRemote) {
      console.log('\n⚠️  ВНИМАНИЕ: Скрипт запущен на удаленном сервере или VS Code подключен к Remote.');
      console.log('   Расширения будут установлены на удаленный сервер.');
      console.log('   Для локальной установки запустите эту команду на ЛОКАЛЬНОЙ машине');
      console.log('   (отключите Remote SSH перед запуском или запустите в отдельном терминале).\n');
    }

    console.log(`📦 Найдено ${vsixFiles.length} расширений для установки:`);
    const homeDir = os.homedir();

    for (const file of vsixFiles) {
      const filePath = join(extensionsDir, file);
      const isUserConfig = file.includes('user-config');

      console.log(`\n🔧 Установка: ${file}`);
      console.log('  📍 Установка через распаковку VSIX...');

      let installed = false;
      try {
        installed = await installExtensionFromVsix(filePath, homeDir, tempRoot);
      } catch (error) {
        console.log(`  ⚠️  Не удалось установить через распаковку: ${error.message}`);
      }

      if (installed) {
        console.log(`  ✅ Успешно установлено: ${file}`);
      } else {
        console.log('  ⚠️  Прямая установка не удалась, пробуем code CLI...');
        try {
          runCodeCli(`code --install-extension "${filePath}" --force`, { cwd: projectRoot });
          console.log(`  ✅ Успешно установлено через code CLI: ${file}`);
          installed = true;
        } catch (error) {
          console.log(`  ⚠️  Не удалось установить через code: ${error.message}`);
        }
      }

      if (!installed) {
        console.log(`\n  📝 Для ручной установки на локальной машине:`);
        console.log(`     cd ${projectRoot}`);
        console.log(`     npm run install-extensions`);
        console.log(`     или вручную:`);
        console.log(`     code --install-extension "${filePath}" --force`);
      }

      if (isUserConfig) {
        console.log(`\n🌐 Установка на удаленный сервер (копирование файлов): ${file}`);
        const remoteInstalled = await installUserConfigToRemote();
        if (remoteInstalled) {
          console.log(`✅ Успешно установлено на удаленный сервер: ${file}`);
        } else {
          console.log(`ℹ️  Удаленный сервер не найден или недоступен: ${file}`);
        }
      }
    }

    if (isRemote) {
      console.log('\n📋 Инструкции для локальной установки:');
      console.log('   Для установки расширений на локальную машину выполните на локальной машине:');
      console.log(`   cd ${projectRoot}`);
      console.log('   npm run install-extensions');
      console.log('\n   Или установите вручную через Command Palette:');
      console.log('   1. Нажмите Ctrl+Shift+P');
      console.log('   2. Выберите "Extensions: Install from VSIX..."');
      console.log('   3. Выберите файлы из папки local-extensions/');
    }

    console.log('\n✨ Установка расширений завершена!');
    console.log('\n' + '='.repeat(50));
    console.log('УСТАНОВКА ЗАВЕРШЕНА');
    console.log('='.repeat(50));
    console.log('\n⚠️  Пожалуйста, ПЕРЕЗАПУСТИТЕ IDE для применения изменений.');
    console.log('='.repeat(50) + '\n');
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.error('❌ Папка local-extensions не найдена');
    } else {
      console.error('❌ Ошибка:', error.message);
    }
    process.exit(1);
  }
}

installExtensions();
