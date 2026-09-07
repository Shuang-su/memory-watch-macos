import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
import unittest
from unittest.mock import patch
import memory_watch as m


class DetectionTests(unittest.TestCase):
    def sample(self, gib, pid=123, started=1):
        return m.Sample(pid, started, 'SceneKitQLThumbnailExtension', int(gib*m.GIB))

    def test_large_process_on_first_scan(self):
        self.assertEqual(m.Detector().update([self.sample(14)], 0)[0][1], 3)

    def test_high_requires_two_samples_and_throttles(self):
        d = m.Detector()
        self.assertFalse(d.update([self.sample(2.5)], 0))
        self.assertEqual(d.update([self.sample(2.5)], 5)[0][1], 2)
        self.assertFalse(d.update([self.sample(2.6)], 10))
        self.assertEqual(d.update([self.sample(4.5)], 15)[0][1], 3)
        self.assertFalse(d.update([self.sample(4.5)], 20))
        self.assertTrue(d.update([self.sample(4.5)], 315))

    def test_growth_and_low_memory_noise(self):
        d = m.Detector()
        d.update([self.sample(.9)], 0)
        self.assertEqual(d.update([self.sample(1.5)], 30)[0][1], 1)
        d = m.Detector()
        d.update([self.sample(.1)], 0)
        self.assertFalse(d.update([self.sample(.8)], 30))

    def test_growth_window_and_reused_pid(self):
        d = m.Detector()
        d.update([self.sample(.9)], 0)
        self.assertFalse(d.update([self.sample(1.8)], 65))
        self.assertFalse(d.update([self.sample(2.5, started=2)], 70))
        self.assertEqual(len(d.tracks), 1)
        self.assertFalse(d.update([], 75))
        self.assertFalse(d.tracks)

    def test_transient_high_does_not_trigger(self):
        d = m.Detector()
        d.update([self.sample(2.1)], 0)
        self.assertFalse(d.update([self.sample(1.9)], 5))
        self.assertFalse(d.update([self.sample(2.1)], 10))

    def test_notify_passes_untrusted_name_as_argument(self):
        message = 'bad" & do shell script "anything\n你好'
        with patch('memory_watch.subprocess.run') as run:
            m.notify(message)
            self.assertEqual(run.call_args.args[0], ['/usr/bin/osascript', '-', message])
            self.assertNotIn(message, run.call_args.kwargs['input'])

    def test_dry_run_and_notification_failure(self):
        alert = [(self.sample(5), 3, 'test')]
        with patch('memory_watch.notify') as notify, patch('memory_watch.logging.Logger') as logger:
            m.emit(alert, True, logger)
            notify.assert_not_called()
            notify.side_effect = OSError('test')
            m.emit(alert, False, logger)
            logger.error.assert_called_once()


if __name__ == '__main__':
    unittest.main()
