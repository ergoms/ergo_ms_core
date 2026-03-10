import { readdir, readFile } from 'fs/promises';
import { join, dirname } from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
import { existsSync } from 'fs';

const require = createRequire(import.meta.url);
const osAbstraction = require('../lib/os-abstraction.cjs');

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const projectRoot = join(__dirname, '..');
const localExtensionsDir = join(projectRoot, 'local-extensions');

/**
 * Получить ID расширения из package.json исходного расширения
 */
async function getExtensionIdFromSource(fileName) {
  try {
    // Формат VSIX: name-version.vsix
    // Пример: ergo-ms-user-config-1.2.0.vsix
    // Извлекаем имя без версии
    const withoutExt = fileName.replace(/\.vsix$/, '');
    const versionMatch = withoutExt.match(/-(\d+\.\d+\.\d+)$/);
    
    if (!versionMatch) {
      return null;
    }
    
    const extensionName = withoutExt.substring(0, versionMatch.index);
    
    // Ищем соответствующее расширение в исходниках
    const extensionsDir = join(projectRoot, 'extensions');
    
    // Пытаемся найти директорию расширения
    const possibleDirs = [
      extensionName, // ergo-ms-user-config
      extensionName.replace('ergo-ms-', ''), // user-config
    ];
    
    for (const dirName of possibleDirs) {
      const extensionDir = join(extensionsDir, dirName);
      const packageJsonPath = join(extensionDir, 'package.json');
      
      if (existsSync(packageJsonPath)) {
        const packageJsonContent = await readFile(packageJsonPath, 'utf-8');
        const packageJson = JSON.parse(packageJsonContent);
        const { publisher, name } = packageJson;
        
        if (publisher && name) {
          // ID расширения в формате publisher.name
          return `${publisher}.${name}`;
        }
        
        if (name) {
          // Если нет publisher, используем только name
          return name;
        }
      }
    }
    
    // Fallback: пытаемся извлечь из имени файла
    // Формат может быть publisher.name или просто name
    if (extensionName.startsWith('ergo-ms-')) {
      // Предполагаем publisher = ergo-ms, name = ergo-ms-*
      return extensionName.replace('ergo-ms-', 'ergo-ms.');
    }
    
    return extensionName;
  } catch (error) {
    console.error(`Ошибка при определении ID расширения для ${fileName}:`, error.message);
    return null;
  }
}

/**
 * Удалить расширение по его ID
 */
function uninstallExtension(extensionId, filePath) {
  try {
    console.log(`🗑️  Удаление расширения: ${extensionId}`);
    
    execSync(`code --uninstall-extension "${extensionId}" --force`, {
      stdio: 'inherit',
      cwd: projectRoot,
      shell: true
    });
    
    console.log(`✅ Успешно удалено: ${extensionId}`);
    return true;
  } catch (error) {
    // Если расширение не установлено, команда вернет ошибку - это нормально
    if (error.message.includes('is not installed') || error.status === 1) {
      console.log(`ℹ️  Расширение не установлено: ${extensionId}`);
      return false;
    }
    console.error(`❌ Ошибка при удалении ${extensionId}:`, error.message);
    return false;
  }
}

/**
 * Удалить расширение на удаленном сервере (для user-config)
 */
async function uninstallUserConfigFromRemote() {
  if (!osAbstraction.supportsRemoteInstall()) {
    return false;
  }

  try {
    const os = await import('os');
    const homeDir = os.default.homedir();
    const fs = await import('fs/promises');
    const remoteDirs = [
      join(homeDir, '.vscode-server', 'extensions'),
      join(homeDir, '.cursor-server', 'extensions'),
    ];

    let removed = false;
    const extensionName = 'ergo-ms-user-config-1.2.0';

    for (const remoteDir of remoteDirs) {
      const targetDir = join(remoteDir, extensionName);
      
      if (existsSync(targetDir)) {
        try {
          await fs.rm(targetDir, { recursive: true, force: true });
          console.log(`  ✅ Удалено с удаленного сервера: ${remoteDir}`);
          removed = true;
        } catch (err) {
          console.log(`  ⚠️  Не удалось удалить с удаленного сервера: ${remoteDir}`);
        }
      }
    }

    return removed;
  } catch (error) {
    console.error(`  ⚠️  Ошибка при удалении с удаленного сервера: ${error.message}`);
    return false;
  }
}

/**
 * Удалить все расширения из VSIX файлов
 */
async function uninstallExtensions() {
  try {
    // Проверяем наличие директории с VSIX файлами
    if (!existsSync(localExtensionsDir)) {
      console.log('❌ Директория local-extensions не найдена');
      return;
    }

    // Получаем список VSIX файлов
    const files = await readdir(localExtensionsDir);
    const vsixFiles = files.filter(file => file.endsWith('.vsix'));

    if (vsixFiles.length === 0) {
      console.log('❌ VSIX файлы не найдены в папке local-extensions');
      return;
    }

    console.log(`🗑️  Найдено ${vsixFiles.length} расширений для удаления:`);

    for (const file of vsixFiles) {
      const filePath = join(localExtensionsDir, file);
      const isUserConfig = file.includes('user-config');
      
      console.log(`\n🗑️  Удаление: ${file}`);
      
      // Получаем ID расширения из исходников
      const extensionId = await getExtensionIdFromSource(file);
      
      if (!extensionId) {
        console.log(`⚠️  Не удалось определить ID расширения: ${file}`);
        continue;
      }
      
      // Удаляем локально
      const uninstalled = uninstallExtension(extensionId, filePath);
      
      // Для user-config также удаляем с удаленного сервера
      if (isUserConfig && uninstalled) {
        console.log(`\n🌐 Удаление с удаленного сервера: ${file}`);
        await uninstallUserConfigFromRemote();
      }
    }

    console.log('\n✨ Удаление расширений завершено!');
  } catch (error) {
    if (error.code === 'ENOENT') {
      console.error('❌ Директория local-extensions не найдена');
    } else {
      console.error('❌ Ошибка:', error.message);
    }
    process.exit(1);
  }
}

uninstallExtensions();

