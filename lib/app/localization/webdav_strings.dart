/// Connection-check copy is kept separate from the main app catalog.
const webDavChinese = <String, String>{
  'WebDAV request failed.': 'WebDAV 请求失败。',
  'Try again later.': '请稍后重试。',
  'Import cloud music': '导入云端已有音乐',
  'Importing cloud music': '正在导入云端音乐',
  'Cloud music import is unavailable.': '暂时无法导入云端音乐。',
  'Existing cloud music needs to be imported into SyncTune. Tap Import cloud music, then sync again.':
      '云端已有音乐尚未建立 SyncTune 识别记录。请点击“导入云端已有音乐”，完成后继续同步。',
  'A required WebDAV file or folder was not found. Check the sync folder and retry.':
      '找不到同步所需的云端文件或目录，请检查同步目录后重试。',
  'The server does not support a required WebDAV operation.':
      '服务器不支持同步所需的 WebDAV 操作。',
  'The cloud storage is full. Free some space and retry.': '云端空间已满，请清理空间后重试。',
  'The server did not provide a strong file ETag. Safe sync is unavailable for this server.':
      '服务器未提供文件的强 ETag 校验标识，暂时无法安全同步。',
  'The WebDAV response or SyncTune metadata is invalid. Check the sync folder and retry.':
      '服务器响应或 SyncTune 识别记录无效，请检查同步目录后重试。',
  'Local folder access or file verification failed. Scan the music folder again and retry.':
      '本地目录访问或文件校验失败，请重新扫描音乐目录后重试。',
  'A cloud file changed during sync. Check again and retry.':
      '同步时云端文件发生变化，请重新检查后重试。',
  'File verification or the final sync check failed. Scan again and retry.':
      '文件校验或同步后的检查失败，请重新扫描后重试。',
  'Sync failed. Check folder access and the sync settings, then retry.':
      '同步失败，请检查目录授权和同步设置后重试。',
  'Check connection status': '检查连接状态',
  'Checking connection…': '正在检查连接…',
  'Connection successful': '连接成功',
  'Connection check failed': '连接检查失败',
  'Connection status': '连接状态',
  'Connection checking is currently unavailable.': '暂时无法检查连接。',
  'The WebDAV server is reachable and the folder is accessible.':
      'WebDAV 服务器连接正常，文件夹可以访问。',
  'Could not check the connection. Check your settings and try again.':
      '无法检查连接，请确认设置后重试。',
  'Could not load the saved password. Enter it again and retry.':
      '无法读取已保存的密码，请重新输入后重试。',
  'Authentication failed. Check your username and password.': '认证失败，请检查用户名和密码。',
  'Access denied. Check your account permissions for this folder.':
      '访问被拒绝，请检查账号对该文件夹的权限。',
  'The WebDAV folder was not found. Check the URL.': '找不到 WebDAV 文件夹，请检查地址。',
  'This server does not support WebDAV connection checks.':
      '该服务器不支持 WebDAV 连接检查。',
  'The server redirected the request. Enter the final HTTPS WebDAV URL.':
      '服务器重定向了请求，请输入最终的 HTTPS WebDAV 地址。',
  'The WebDAV server returned an unexpected response. Try again later.':
      'WebDAV 服务器返回了异常响应，请稍后重试。',
  'The URL did not return an accessible WebDAV folder. Check the URL and permissions.':
      '该地址未返回可访问的 WebDAV 文件夹，请检查地址和权限。',
  'The connection timed out. Check the server and try again.':
      '连接超时，请检查服务器后重试。',
  'The server certificate could not be verified.': '无法验证服务器证书。',
  'Could not reach the WebDAV server. Check the URL and network.':
      '无法连接 WebDAV 服务器，请检查地址和网络。',
};
