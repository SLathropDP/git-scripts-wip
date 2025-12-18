// NOTE: Some reporter packages are published as CommonJS (CJS). When this wrapper is ESM,
// Node may load a CJS module such that the exported value appears on the `default`
// property (i.e. `require('...')` vs `import ...`). The fallback below handles both
// cases so the wrapper works whether the reporter is published as ESM or CJS and
// avoids runtime errors like "X is not a constructor" or "default is undefined".
import SpecReporterCjs from 'jest-mocha-spec-reporter';
const SpecReporter = SpecReporterCjs && SpecReporterCjs.default ? SpecReporterCjs.default : SpecReporterCjs;

export default class FilterMochaSpecReporter {
  constructor(globalConfig, options) {
    this._delegate = new SpecReporter(globalConfig, options);
    this.getLastError = this._delegate.getLastError ? this._delegate.getLastError.bind(this._delegate) : undefined;
  }

  onRunStart(results, options) {
    return this._delegate.onRunStart ? this._delegate.onRunStart(results, options) : undefined;
  }

  onTestResult(test, testResult, aggregatedResult) {
    const filteredTestResult = {
      ...testResult,
      testResults: testResult.testResults.filter(r => r.status !== 'pending')
    };

    const pendingHere = testResult.testResults.filter(r => r.status === 'pending').length;
    aggregatedResult && typeof aggregatedResult.numPendingTests === 'number'
      ? aggregatedResult.numPendingTests = Math.max(0, (aggregatedResult.numPendingTests || 0) - pendingHere)
      : null;

    return this._delegate.onTestResult ? this._delegate.onTestResult(test, filteredTestResult, aggregatedResult) : undefined;
  }

  onRunComplete(contexts, aggregatedResult) {
    return this._delegate.onRunComplete ? this._delegate.onRunComplete(contexts, aggregatedResult) : undefined;
  }
}
