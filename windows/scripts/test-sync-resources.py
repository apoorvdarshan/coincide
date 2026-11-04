#!/usr/bin/env python3
"""Regression checks for platform-independent extraction of real UI labels."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('windows_resources', Path(__file__).with_name('sync-resources.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ResourceLabels(unittest.TestCase):
    def test_panel_automation_ids_are_not_english_labels(self):
        original = MODULE.ROOT
        try:
            with tempfile.TemporaryDirectory() as directory:
                MODULE.ROOT = Path(directory)
                app = MODULE.ROOT / 'App'
                app.mkdir()
                (app / 'main.cpp').write_text('label(L"Cancel", L"Cancel"); button(L"Save", L"Save", L"SaveApp");', encoding='utf-8')
                (app / 'zPanel.h').write_text('button(L"Cancel", L"CancelProviderAccount"); button(L"Check profile", L"CheckProfile"); label(L"", L"PanelStatus"); command(L"New Bot", L"BotNew", [](auto&){}); note(L"Bot instructions"); button(L"Cancel", L"AutomationOnly", [](auto&){}); button(L"Submit Review", L"ReviewSend", [](auto&){});', encoding='utf-8')
                values = MODULE.labels()
                self.assertEqual(values['Cancel'], 'Cancel')
                self.assertEqual(values['Save'], 'Save')
                self.assertEqual(values[MODULE.ui_key('Check profile')], 'Check profile')
                self.assertNotIn('CancelProviderAccount', values.values())
                self.assertNotIn('CheckProfile', values.values())
                self.assertNotIn('', values)
                self.assertNotIn('PanelStatus', values.values())
                self.assertNotIn('AutomationOnly', values.values())
                self.assertEqual(values[MODULE.ui_key('New Bot')], 'New Bot')
                self.assertEqual(values[MODULE.ui_key('Bot instructions')], 'Bot instructions')
                self.assertEqual(values[MODULE.ui_key('Submit Review')], 'Submit Review')
                self.assertNotIn('ReviewSend', values.values())
        finally:
            MODULE.ROOT = original


if __name__ == '__main__':
    unittest.main()
