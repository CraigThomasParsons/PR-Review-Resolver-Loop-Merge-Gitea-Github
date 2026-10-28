"""Exercise the shipped inline workflow against a fake Gitea API, without secrets."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / '.gitea/workflows/label-new-pr.yml'


class LabelNewPrTests(unittest.TestCase):
    def run_workflow(self, changes: dict | None = None, failure: str = '') -> tuple:
        pr = {'state': 'open', 'draft': False, 'user': {'login': 'developer'},
              'title': 'A feature', 'head': {'ref': 'feature/example'}, 'labels': []}
        pr.update(changes or {})
        source = WORKFLOW.read_text().split("<<'JS_EOF'\n", 1)[1].split('          JS_EOF', 1)[0]
        source = '\n'.join(line[10:] for line in source.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'workflow.cjs'
            calls = root / 'calls.jsonl'
            script.write_text('''
const fs = require('node:fs');
global.fetch = async (url, options) => {
  fs.appendFileSync(process.env.CALLS, JSON.stringify({url, options}) + '\\n');
  if (url.includes('/pulls/')) return {ok: process.env.FAILURE !== 'pr', status: 503,
    json: async () => JSON.parse(process.env.FAKE_PR)};
  if (options.method === 'POST') return {ok: true};
  const page = Number(new URL(url).searchParams.get('page'));
  return {ok: process.env.FAILURE !== 'labels', status: 503, json: async () =>
    page === 1 ? [{id: 1, name: 'bug'}] : [{id: 2, name: 'review:requested'}]};
};
''' + source)
            result = subprocess.run(['node', str(script)], capture_output=True, text=True,
                                    env={**os.environ, 'GITEA_API_URL': 'http://example.test/api/v1',
                                         'REPO': 'owner/repo', 'PR_NUMBER': '7', 'TOKEN': 'fixture',
                                         'CALLS': str(calls), 'FAKE_PR': json.dumps(pr), 'FAILURE': failure})
            requests = [json.loads(line) for line in calls.read_text().splitlines()]
            return result, requests

    def test_trusted_workflow_and_no_checkout(self) -> None:
        source = WORKFLOW.read_text()
        self.assertIn('  pull_request_target:', source)
        self.assertNotIn('  pull_request:', source)
        self.assertNotIn('uses: actions/checkout', source)

    def test_pages_until_label_found_and_adds_only_requested(self) -> None:
        result, calls = self.run_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('page=2', calls[-2]['url'])
        self.assertEqual(json.loads(calls[-1]['options']['body']), {'labels': [2]})

    def test_current_state_prevents_labeling(self) -> None:
        cases = [{'draft': True}, {'state': 'closed'}, {'user': {'login': 'tool[bot]'}},
                 {'title': 'docblock-backfill'}, {'head': {'ref': 'docblock-backfill/run'}}]
        cases += [{'labels': [{'name': name}]} for name in ['agent:claimed', 'review:needs-human', 'night:hold']]
        for change in cases:
            with self.subTest(change=change):
                result, calls = self.run_workflow(change)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(call['options'].get('method') == 'POST' for call in calls))

    def test_failed_reads_never_mutate_labels(self) -> None:
        for failure in ['pr', 'labels']:
            result, calls = self.run_workflow(failure=failure)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(call['options'].get('method') == 'POST' for call in calls))


if __name__ == '__main__':
    unittest.main()
