const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './test_web',
  reporter: 'list',
  use: {
    browserName: 'chromium',
  },
});
