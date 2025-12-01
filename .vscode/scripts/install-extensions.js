import { readdir, mkdir, readdir as readdirSync } from 'fs/promises';
import { join, dirname } from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import os from 'os';
import { existsSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const projectRoot = join(__dirname, '..');
const extensionsDir = join(projectRoot, 'local-extensions');

/**
 * Получить все директории расширений удаленного сервера
 */
function getRemoteExtensionsDirs() {
  const dirs = [];
  const homeDir = os.homedir();
  const isWindows = process.platform === 'win32';

  if (!isWindows) {
    // Linux/Mac - проверяем директории удаленного сервера
    const possibleDirs = [
      join(homeDir, '.vscode-server', 'extensions'),
      join(homeDir, '.cursor-server', 'extensions'),
    ];

    for (const dir of possibleDirs) {
      // Проверяем, существует ли директория сервера (признак подключенного удаленного сервера)
      const serverDir = join(dir, '..');
      if (existsSync(serverDir)) {
        dirs.push(dir);
      }
    }
  }

  return dirs;
}

/**
 * Распаковать VSIX файл во временную директорию
 */
async function extractVsixFile(vsixPath, extractDir) {
  try {
    const AdmZip = (await import('adm-zip')).default;
    const zip = new AdmZip(vsixPath);
    zip.extractAllTo(extractDir, true);
    return join(extractDir, 'extension');
  } catch (error) {
    // Если adm-zip недоступен, пробуем другой способ
    console.error(`Ошибка при распаковке VSIX: ${error.message}`);
    return null;
  }
}

/**
 * Установить расширение локально (копирование в локальные директории)
 */
async function installExtensionLocally(vsixPath, extensionId) {
  try {
    // Создаем временную директорию для распаковки
    const tempDir = join(projectRoot, '.temp-extract', extensionId);
    const fs = await import('fs/promises');
    
    // Очищаем временную директорию
    if (existsSync(tempDir)) {
      await fs.rm(tempDir, { recursive: true, force: true });
    }
    await fs.mkdir(tempDir, { recursive: true });

    // Распаковываем VSIX
    const extractedDir = await extractVsixFile(vsixPath, tempDir);
    if (!extractedDir || !existsSync(extractedDir)) {
      console.log(`  ⚠️  Не удалось распаковать VSIX, пропускаем локальную установку`);
      await fs.rm(tempDir, { recursive: true, force: true }).catch(() => {});
      return false;
    }

    // Читаем package.json для получения имени расширения
    const packageJsonPath = join(extractedDir, 'package.json');
    if (!existsSync(packageJsonPath)) {
      console.log(`  ⚠️  package.json не найден, пропускаем локальную установку`);
      await fs.rm(tempDir, { recursive: true, force: true }).catch(() => {});
      return false;
    }

    const packageJsonContent = await fs.readFile(packageJsonPath, 'utf-8');
    const packageJson = JSON.parse(packageJsonContent);
    const { publisher, name, version } = packageJson;
    
    if (!publisher || !name || !version) {
      console.log(`  ⚠️  Отсутствуют необходимые поля в package.json`);
      await fs.rm(tempDir, { recursive: true, force: true }).catch(() => {});
      return false;
    }

    const extensionDirName = `${publisher}.${name}-${version}`;
    const homeDir = os.homedir();
    const isWindows = process.platform === 'win32';

    // Определяем локальные директории расширений
    const localDirs = [];
    if (isWindows) {
      localDirs.push(join(homeDir, '.vscode', 'extensions'));
      localDirs.push(join(homeDir, '.cursor', 'extensions'));
    } else {
      // Linux/Mac - проверяем через SSH переменные окружения
      // Если мы на удаленном сервере, локальные директории недоступны напрямую
      // В этом случае используем команду code с переменной окружения
      return false;
    }

    let installed = false;
    for (const localDir of localDirs) {
      try {
        await fs.mkdir(localDir, { recursive: true });
        const targetDir = join(localDir, extensionDirName);
        
        // Удаляем старое расширение
        if (existsSync(targetDir)) {
          await fs.rm(targetDir, { recursive: true, force: true });
        }
        
        // Копируем расширение
        const copied = await copyDirectory(extractedDir, targetDir);
        if (copied) {
          installed = true;
        }
      } catch (err) {
        // Пропускаем директорию, если недоступна
      }
    }

    // Очищаем временную директорию
    await fs.rm(tempDir, { recursive: true, force: true }).catch(() => {});

    return installed;
  } catch (error) {
    console.error(`  ⚠️  Ошибка при локальной установке: ${error.message}`);
    return false;
  }
}

/**
 * Рекурсивно скопировать директорию
 */
async function copyDirectory(sourceDir, targetDir) {
  try {
    const fs = await import('fs/promises');
    
    // Создаем целевую директорию
    await fs.mkdir(targetDir, { recursive: true });

    // Читаем содержимое исходной директории
    const entries = await readdirSync(sourceDir, { withFileTypes: true });

    for (const entry of entries) {
      const sourcePath = join(sourceDir, entry.name);
      const targetPath = join(targetDir, entry.name);

      if (entry.isDirectory()) {
        // Рекурсивно копируем поддиректории
        await copyDirectory(sourcePath, targetPath);
      } else {
        // Копируем файлы
        await fs.copyFile(sourcePath, targetPath);
      }
    }

    return true;
  } catch (error) {
    console.error(`Ошибка при копировании директории: ${error.message}`);
    return false;
  }
}

/**
 * Установить user-config расширение на удаленный сервер
 */
async function installUserConfigToRemote() {
  const homeDir = os.homedir();
  const isWindows = process.platform === 'win32';

  if (isWindows) {
    // На Windows удаленные серверы устанавливаются через Remote API
    // Обычная установка через code --install-extension должна работать
    return false;
  }

  try {
    // Используем исходную директорию расширения (относительно .vscode)
    const sourceExtensionDir = join(projectRoot, 'extensions', 'user-config');
    
    // Проверяем, существует ли исходная директория
    if (!existsSync(sourceExtensionDir)) {
      console.log('  ℹ️  Исходная директория расширения не найдена, пропускаем установку на удаленный сервер');
      return false;
    }

    // Получаем список директорий удаленного сервера
    const remoteDirs = getRemoteExtensionsDirs();
    
    if (remoteDirs.length === 0) {
      return false;
    }

    let installed = false;
    // Имя расширения с версией (формат: publisher.name-version)
    const extensionName = 'ergo-ms-user-config-1.2.0';

    for (const remoteDir of remoteDirs) {
      try {
        // Создаем директорию расширений удаленного сервера, если её нет
        await mkdir(remoteDir, { recursive: true });
        
        const targetDir = join(remoteDir, extensionName);
        
        // Удаляем старое расширение, если существует
        const fs = await import('fs/promises');
        if (existsSync(targetDir)) {
          await fs.rm(targetDir, { recursive: true, force: true });
        }
        
        // Копируем расширение
        const copied = await copyDirectory(sourceExtensionDir, targetDir);
        if (copied) {
          console.log(`  ✅ Установлено на удаленный сервер: ${remoteDir}`);
          installed = true;
        }
      } catch (err) {
        // Директория недоступна - пропускаем
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

    // Проверяем, запущен ли скрипт на удаленном сервере или подключен ли VS Code к Remote
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

    for (const file of vsixFiles) {
      const filePath = join(extensionsDir, file);
      const isUserConfig = file.includes('user-config');
      
      console.log(`\n🔧 Установка: ${file}`);
      
      try {
        // Определяем ID расширения из имени файла
        const extensionId = file.replace(/\.vsix$/, '');
        
        // Устанавливаем через команду code (на удаленный сервер, если подключен)
        console.log(`  📍 Установка на текущий хост (удаленный сервер)...`);
        try {
        execSync(`code --install-extension "${filePath}" --force`, {
          stdio: 'inherit',
          cwd: projectRoot,
          shell: true
        });
          console.log(`  ✅ Успешно установлено на текущий хост: ${file}`);
        } catch (error) {
          console.log(`  ⚠️  Не удалось установить через code: ${error.message}`);
        }
        
        console.log(`\n  📝 Для установки на локальную машину:`);
        console.log(`     Выполните на ЛОКАЛЬНОЙ машине (не на удаленном сервере):`);
        console.log(`     cd ${projectRoot}`);
        console.log(`     npm run install-extensions`);
        console.log(`     или вручную:`);
        console.log(`     code --install-extension "${filePath}" --force`);
        
        // Для user-config также устанавливаем на удаленный сервер через копирование
        if (isUserConfig) {
          console.log(`\n🌐 Установка на удаленный сервер (копирование файлов): ${file}`);
          const remoteInstalled = await installUserConfigToRemote();
          if (remoteInstalled) {
            console.log(`✅ Успешно установлено на удаленный сервер: ${file}`);
          } else {
            console.log(`ℹ️  Удаленный сервер не найден или недоступен: ${file}`);
          }
        }
      } catch (error) {
        console.error(`❌ Ошибка при установке ${file}:`, error.message);
      }
    }

    // Показываем финальные инструкции для локальной установки
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
    
    // Показываем сообщение о необходимости перезапуска IDE
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

