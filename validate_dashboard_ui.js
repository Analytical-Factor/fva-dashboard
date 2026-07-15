const fs = require("fs");
const os = require("os");
const path = require("path");
const { pathToFileURL } = require("url");
const { chromium } = require("playwright");


const ROOT = __dirname;
const DATA_PREFIX = "window.auditDashboardData=";
const rawData = fs.readFileSync(path.join(ROOT, "audit-data.js"), "utf8");
const data = JSON.parse(
  rawData.slice(rawData.indexOf(DATA_PREFIX) + DATA_PREFIX.length, rawData.lastIndexOf(";"))
);
const numberFormat = new Intl.NumberFormat("en-US");


function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}


function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        field += character;
      }
    } else if (character === '"') {
      quoted = true;
    } else if (character === ",") {
      row.push(field);
      field = "";
    } else if (character === "\n") {
      row.push(field.replace(/\r$/, ""));
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += character;
    }
  }

  if (field || row.length) {
    row.push(field.replace(/\r$/, ""));
    rows.push(row);
  }
  return rows;
}


function buildActivityMetrics() {
  const metrics = new Map();
  data.months.slice(-6).forEach((month) => {
    data.partsByMonth[month.key].forEach((part) => {
      const values = metrics.get(part[0]) || { automatic: 0, adjusted: 0, accepted: 0 };
      values.automatic += part[3] === "Automatically Reconciled" ? 1 : 0;
      values.adjusted += part[5] ? 1 : 0;
      values.accepted += part[3].startsWith("Accepted with") ? 1 : 0;
      metrics.set(part[0], values);
    });
  });
  return metrics;
}


function aggregateParts() {
  const items = new Map();
  data.months.forEach((month) => {
    data.partsByMonth[month.key].forEach((part) => {
      const item = items.get(part[0]) || {
        item: part[0],
        description: part[1],
        abc: part[2],
        periods: {},
      };
      item.description = part[1];
      item.abc = part[2];
      item.periods[month.key] = part;
      items.set(item.item, item);
    });
  });
  return [...items.values()];
}


async function saveDownload(page, selector, filename) {
  const downloadPromise = page.waitForEvent("download");
  await page.locator(selector).click();
  const download = await downloadPromise;
  const outputPath = path.join(os.tmpdir(), filename);
  await download.saveAs(outputPath);
  const rows = parseCsv(fs.readFileSync(outputPath, "utf8"));
  fs.unlinkSync(outputPath);
  return rows;
}


async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  const browserErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") {
      browserErrors.push(message.text());
    }
  });
  page.on("pageerror", (error) => browserErrors.push(error.message));

  try {
    const indexUrl = pathToFileURL(path.join(ROOT, "index.html")).href;
    const loginUrl = pathToFileURL(path.join(ROOT, "login.html")).href;

    await page.goto(indexUrl);
    await page.waitForURL(loginUrl);
    assert(await page.locator("#loginForm").isVisible(), "Unauthenticated dashboard access did not redirect to login");

    await page.locator("#username").fill("Sharon");
    await page.locator("#password").fill("incorrect");
    await page.locator("#loginForm button[type=submit]").click();
    assert(await page.locator("#loginError").isVisible(), "Invalid credentials were not rejected");
    assert(page.url() === loginUrl, "Invalid credentials left the login page");

    await page.locator("#username").fill("sharon");
    await page.locator("#password").fill("AFUser123");
    await page.locator("#loginForm button[type=submit]").click();
    assert(await page.locator("#loginError").isVisible(), "Incorrect username casing was not rejected");

    await page.locator("#username").fill("Sharon");
    await page.locator("#password").fill("AFUser123");
    await page.locator("#loginForm button[type=submit]").click();
    await page.waitForURL(indexUrl);
    await page.waitForSelector("#monthStrip .month");

    assert(
      (await page.locator("#monthStrip .month").count()) === data.months.length,
      "Month selector count does not match audit-data.js"
    );
    assert(
      (await page.locator("#monthlyBars .bar-group").count()) === data.months.length,
      "Monthly status bar count does not match audit-data.js"
    );

    for (let index = 0; index < data.months.length; index += 1) {
      const month = data.months[index];
      await page.locator('.month[data-index="' + index + '"]').click();

      const actualSources = await page.locator("#sourceList .source-row .count").allInnerTexts();
      const actualAbcTotals = await page.locator("#abcList .abc-total").allInnerTexts();
      assert(
        (await page.locator("#totalValue").innerText()) === numberFormat.format(month.total),
        month.key + ": audited item card mismatch"
      );
      assert(
        (await page.locator("#reconciledValue").innerText()) === numberFormat.format(month.reconciled),
        month.key + ": reconciled card mismatch"
      );
      assert(
        (await page.locator("#exceptionValue").innerText()) === numberFormat.format(month.exceptions),
        month.key + ": exception card mismatch"
      );
      assert(
        (await page.locator("#overrideValue").innerText()) === numberFormat.format(month.overrides),
        month.key + ": planner override card mismatch"
      );
      assert(
        (await page.locator("#automaticCount").innerText()) === numberFormat.format(month.automatic),
        month.key + ": automatic reconciliation mismatch"
      );
      assert(
        (await page.locator("#manualCount").innerText()) === numberFormat.format(month.manual),
        month.key + ": manual reconciliation mismatch"
      );
      assert(
        JSON.stringify(actualSources)
          === JSON.stringify(month.sources.map((source) => numberFormat.format(source.count))),
        month.key + ": forecast source counts mismatch"
      );
      assert(
        JSON.stringify(actualAbcTotals)
          === JSON.stringify(month.abc.map((row) => numberFormat.format(row.total))),
        month.key + ": ABC totals mismatch"
      );

      const reconciledPlannerLabel =
        numberFormat.format(month.planner.reconciled.withOverrides)
        + " items with overrides and "
        + numberFormat.format(month.planner.reconciled.withoutOverrides)
        + " without overrides";
      const exceptionPlannerLabel =
        numberFormat.format(month.planner.exceptions.withOverrides)
        + " items with overrides and "
        + numberFormat.format(month.planner.exceptions.withoutOverrides)
        + " without overrides";
      assert(
        (await page.locator("#reconciledPlannerTrack").getAttribute("aria-label"))
          === reconciledPlannerLabel,
        month.key + ": reconciled planner split mismatch"
      );
      assert(
        (await page.locator("#exceptionPlannerTrack").getAttribute("aria-label"))
          === exceptionPlannerLabel,
        month.key + ": exception planner split mismatch"
      );

      const kpiRows = await saveDownload(
        page,
        "#exportKpi",
        "audit-kpis-" + month.key + "-validation.csv"
      );
      const expectedKpiRows = [
        ["Section", "Metric", "Exceptions", "Reconciled", "Total"],
        ["Overall", "Total Items", month.exceptions, month.reconciled, month.total],
        ["Reconciliation", "Automatically Reconciled", "", month.automatic, month.automatic],
        ["Reconciliation", "Manually Reconciled", "", month.manual, month.manual],
        [
          "Planner Overrides",
          "With User Overrides",
          month.planner.exceptions.withOverrides,
          month.planner.reconciled.withOverrides,
          month.overrides,
        ],
        ...month.sources.map((source) => [
          "Forecast Source",
          source.label,
          source.exceptions,
          source.reconciled,
          source.count,
        ]),
        ...month.abc.map((row) => [
          "ABC Class",
          row.label,
          row.exceptions,
          row.reconciled,
          row.total,
        ]),
      ].map((row) => row.map(String));
      assert(
        kpiRows.length === expectedKpiRows.length,
        month.key + ": KPI export row count mismatch"
      );
      assert(
        JSON.stringify(kpiRows) === JSON.stringify(expectedKpiRows),
        month.key + ": KPI export content mismatch"
      );
    }

    await page.locator('[data-view="parts"]').click();
    await page.locator('[data-period="all"]').click();

    const items = aggregateParts();
    const activityMetrics = buildActivityMetrics();
    assert(
      (await page.locator("#partCount").innerText()) === numberFormat.format(items.length),
      "All-month Part-Level item count mismatch"
    );
    assert(
      (await page.locator("#partTableHead .part-period-heading").count()) === data.months.length,
      "All-month Part-Level period header count mismatch"
    );

    const partRows = await saveDownload(
      page,
      "#exportParts",
      "audit-parts-all-months-validation.csv"
    );
    assert(partRows.length === items.length + 1, "Part-Level export row count mismatch");

    const monthKeys = data.months.map((month) => month.key);
    items.forEach((item, index) => {
      const metrics = activityMetrics.get(item.item);
      const periods = monthKeys.flatMap((key) => (
        item.periods[key] ? [item.periods[key][3], item.periods[key][4]] : ["", ""]
      ));
      const expected = [
        item.item,
        item.description,
        item.abc,
        ...periods,
        String(metrics.automatic),
        String(metrics.adjusted),
        String(metrics.accepted),
      ];
      assert(
        JSON.stringify(partRows[index + 1]) === JSON.stringify(expected),
        "Part-Level export mismatch for " + item.item
      );
    });

    const sample = items.find((item) => monthKeys.every((key) => item.periods[key]));
    await page.locator("#partSearch").fill(sample.item);
    assert((await page.locator("#partCount").innerText()) === "1", "Part search mismatch");
    const sampleText = await page.locator("#simpleParts tr").first().innerText();
    monthKeys.forEach((key) => {
      assert(sampleText.includes(sample.periods[key][3]), sample.item + ": missing status " + key);
      assert(sampleText.includes(sample.periods[key][4]), sample.item + ": missing source " + key);
    });
    const metrics = activityMetrics.get(sample.item);
    const metricCells = await page
      .locator("#simpleParts tr")
      .first()
      .locator(".metric-cell")
      .allInnerTexts();
    assert(
      JSON.stringify(metricCells)
        === JSON.stringify([
          String(metrics.automatic),
          String(metrics.adjusted),
          String(metrics.accepted),
        ]),
      sample.item + ": activity metrics mismatch"
    );
    assert(browserErrors.length === 0, "Browser errors: " + browserErrors.join("; "));

    await page.locator("#logoutButton").click();
    await page.waitForURL(loginUrl);
    assert(await page.locator("#loginForm").isVisible(), "Logout did not return to login");
    assert(
      await page.evaluate(() => sessionStorage.getItem("afAuditDashboardAuthenticated")) === null,
      "Logout did not clear the authentication session"
    );

    console.log(
      "Browser dashboard validation: PASS ("
      + data.months.length
      + " months, "
      + items.length.toLocaleString("en-US")
      + " exported items, sample "
      + sample.item
      + ")"
    );
  } finally {
    await browser.close();
  }
}


main().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
