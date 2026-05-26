const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const PORT = 8080;
const PUBLIC_DIR = path.resolve(__dirname, 'build', 'web');

const MIME_TYPES = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.wasm': 'application/wasm',
  '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
  console.log(`[SERVER] Request: ${req.method} ${req.url}`);
  
  let safePath;
  try {
    safePath = decodeURIComponent(req.url.split('?')[0]);
  } catch (_) {
    res.statusCode = 400;
    res.end('Bad Request');
    return;
  }
  if (safePath === '/') {
    safePath = 'index.html';
  } else {
    safePath = safePath.replace(/^[/\\]+/, '');
  }

  const filePath = path.resolve(PUBLIC_DIR, safePath);
  const resolvedPath = path.resolve(filePath);

  const relativePath = path.relative(PUBLIC_DIR, resolvedPath);
  const isSafe =
    relativePath === '' ||
    (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
  if (!isSafe) {
    res.statusCode = 403;
    res.end('Forbidden');
    return;
  }
  
  fs.stat(filePath, (err, stats) => {
    if (err || !stats.isFile()) {
      // Fallback to index.html for Single Page Application routing if not found
      const fallbackPath = path.join(PUBLIC_DIR, 'index.html');
      fs.readFile(fallbackPath, (err, content) => {
        if (err) {
          res.statusCode = 404;
          res.end('Not Found');
        } else {
          res.writeHead(200, { 'Content-Type': 'text/html' });
          res.end(content);
        }
      });
      return;
    }
    
    fs.readFile(filePath, (err, content) => {
      if (err) {
        res.statusCode = 500;
        res.end('Internal Server Error');
        return;
      }
      
      const ext = path.extname(filePath).toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';
      
      res.writeHead(200, { 'Content-Type': contentType });
      res.end(content);
    });
  });
});

server.listen(PORT, () => {
  console.log(`[SERVER] Static server running at http://localhost:${PORT}`);
  console.log(`[SERVER] Serving directory: ${PUBLIC_DIR}`);
});
