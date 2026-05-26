const path = require('node:path');
const { test, expect } = require('@playwright/test');

const xtermPath = path.join(__dirname, '..', 'web', 'xterm.js');

async function createTerminal(page) {
  await page.setContent(`
    <!doctype html>
    <html>
      <head>
        <style>
          html, body, #terminal {
            width: 900px;
            height: 360px;
            margin: 0;
          }
        </style>
      </head>
      <body><div id="terminal"></div></body>
    </html>
  `);
  await page.addScriptTag({ path: xtermPath });
  await page.evaluate(() => {
    window.term = new window.Terminal({
      cols: 100,
      rows: 24,
      scrollback: 1000,
      cursorBlink: true,
    });
    window.forwardedData = [];
    window.suppressData = false;
    window.term.onData((data) => {
      if (!window.suppressData) {
        window.forwardedData.push(data);
      }
    });
    window.term.open(document.getElementById('terminal'));
  });
}

async function writeReplay(page, data) {
  await page.evaluate(async (replayData) => {
    window.suppressData = true;
    await new Promise((resolve) => window.term.write(replayData, resolve));
    await new Promise((resolve) => setTimeout(resolve, 50));
    window.suppressData = false;
  }, data);
}

function promptRows() {
  const divider = '-'.repeat(103);
  return [
    '    Antigravity CLI 1.0.2',
    '    Gemini 3.5 Flash (High)',
    '    /mnt/c/Users/iamst/development-windows/argus/worktrees/fix-terminal-layout',
    '',
    divider,
    '----',
    '>',
    divider,
    'dberrios@rogflowz13:/mnt/c/Users/iamst$ ',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    'dberrios@rogflowz13:/mnt/c/Users/iamst$ ',
  ];
}

function serializeRows(rows, cols = 100, cursorRow = 9, cursorCol = 41) {
  return `\x1b[?25h${rows
    .map((row) => row.slice(0, cols).trimEnd())
    .join('\r\n')}\x1b[${cursorRow};${cursorCol}H`;
}

test('snapshot replay leaves xterm cursor at daemon prompt, not trailing stale rows', async ({ page }) => {
  await createTerminal(page);
  await writeReplay(page, serializeRows(promptRows()));

  const cursor = await page.evaluate(() => ({
    x: window.term.buffer.active.cursorX,
    y: window.term.buffer.active.cursorY,
    line: window.term.buffer.active
      .getLine(window.term.buffer.active.baseY + window.term.buffer.active.cursorY)
      .translateToString(true),
  }));

  expect(cursor).toEqual({
    x: 40,
    y: 8,
    line: 'dberrios@rogflowz13:/mnt/c/Users/iamst$',
  });
});

test('writing live content after snapshot replay appends exactly at the cursor position without overwrite', async ({ page }) => {
  await createTerminal(page);
  await writeReplay(page, serializeRows(promptRows()));

  // Simulate writing live output "echo hello" immediately after replay
  await page.evaluate(async () => {
    await new Promise((resolve) => window.term.write('echo hello', resolve));
  });

  const cursor = await page.evaluate(() => ({
    x: window.term.buffer.active.cursorX,
    y: window.term.buffer.active.cursorY,
    line: window.term.buffer.active
      .getLine(window.term.buffer.active.baseY + window.term.buffer.active.cursorY)
      .translateToString(true),
  }));

  // The cursor should be at column 50 (40 for prompt + 10 for "echo hello")
  expect(cursor).toEqual({
    x: 50,
    y: 8,
    line: 'dberrios@rogflowz13:/mnt/c/Users/iamst$ echo hello',
  });
});

test('snapshot replay must write only the selected viewport slice before moving cursor', async ({ page }) => {
  await createTerminal(page);
  const overflowingRows = [
    ...promptRows(),
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    'dberrios@rogflowz13:/mnt/c/Users/iamst$ ',
  ];

  await writeReplay(page, serializeRows(overflowingRows));
  const fullReplayCursor = await page.evaluate(() => ({
    x: window.term.buffer.active.cursorX,
    y: window.term.buffer.active.cursorY,
    line: window.term.buffer.active
      .getLine(window.term.buffer.active.baseY + window.term.buffer.active.cursorY)
      .translateToString(true),
  }));
  expect(fullReplayCursor.line).not.toBe('dberrios@rogflowz13:/mnt/c/Users/iamst$');

  await page.evaluate(() => window.term.reset());
  await writeReplay(page, serializeRows(overflowingRows.slice(0, 24), 100, 9, 41));
  const slicedReplayCursor = await page.evaluate(() => ({
    x: window.term.buffer.active.cursorX,
    y: window.term.buffer.active.cursorY,
    line: window.term.buffer.active
      .getLine(window.term.buffer.active.baseY + window.term.buffer.active.cursorY)
      .translateToString(true),
  }));

  expect(slicedReplayCursor).toEqual({
    x: 40,
    y: 8,
    line: 'dberrios@rogflowz13:/mnt/c/Users/iamst$',
  });
});

test('snapshot replay suppresses terminal-generated replies from onData forwarding', async ({ page }) => {
  await createTerminal(page);
  await writeReplay(page, '\x1b[6n');
  await page.waitForTimeout(100);

  const forwardedDuringReplay = await page.evaluate(() => window.forwardedData);
  expect(forwardedDuringReplay).toEqual([]);

  await page.evaluate(() => window.term.input('x'));
  const forwardedAfterReplay = await page.evaluate(() => window.forwardedData);
  expect(forwardedAfterReplay).toEqual(['x']);
});

test('real web client captures and routes keyboard input inside the Flutter Web application', async ({ page }) => {
  await page.goto('http://localhost:8080/?mock=true', { waitUntil: 'networkidle', timeout: 15000 });
  await page.waitForTimeout(4000);

  const activeTermExists = await page.evaluate(() => typeof window.activeTerm !== 'undefined');
  expect(activeTermExists).toBe(true);

  await page.mouse.click(450, 200);
  await page.waitForTimeout(500);

  await page.keyboard.type('pwd');
  await page.waitForTimeout(500);

  const activeLine = await page.evaluate(() => {
    const term = window.activeTerm;
    const active = term.buffer.active;
    const y = active.baseY + active.cursorY;
    return active.getLine(y).translateToString(true);
  });

  expect(activeLine).toContain('pwd');
});
