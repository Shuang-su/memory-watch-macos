import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cli"))
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
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


class AdaptivePolicyTests(unittest.TestCase):
    def test_endpoints_interpolation_and_clamps(self):
        for ram, physical, virtual in [
            (8, 4, 8), (16, 4, 8),
            (64, 5.548387096774194, 14.967741935483872),
            (128, 7.612903225806452, 24.258064516129032),
            (256, 11.741935483870968, 42.83870967741935),
            (512, 20, 80), (1024, 20, 80),
        ]:
            with self.subTest(ram=ram):
                limit, growth = m.adaptive_limits(ram*m.GIB)
                self.assertAlmostEqual(limit/m.GIB, physical)
                self.assertAlmostEqual(growth/m.GIB, virtual)
        self.assertEqual(m.adaptive_limits(None), (4*m.GIB, 8*m.GIB))

    def test_defaults_and_independent_explicit_overrides(self):
        self.assertEqual(m.resolve_thresholds(512*m.GIB), (10*m.GIB, 20*m.GIB, 80*m.GIB))
        self.assertEqual(m.resolve_thresholds(512*m.GIB, 3, 7), (3*m.GIB, 7*m.GIB, 80*m.GIB))
        self.assertEqual(m.resolve_thresholds(512*m.GIB, 3), (3*m.GIB, 20*m.GIB, 80*m.GIB))
        with self.assertRaises(ValueError):
            m.resolve_thresholds(512*m.GIB, critical_gib=4)


class VirtualGrowthTests(unittest.TestCase):
    path = next(path for path in m.PREVIEW_PATHS if path.endswith('/HydraRenderingService'))

    def sample(self, virtual, started=1, path=None, footprint=.1):
        return m.Sample(123, started, 'HydraRenderingService', int(footprint*m.GIB),
                        virtual_bytes=None if virtual is None else int(virtual*m.GIB),
                        executable_path=self.path if path is None else path)

    def test_huge_first_virtual_value_is_only_a_baseline(self):
        d = m.Detector(virtual_growth=80*m.GIB)
        self.assertFalse(d.update([self.sample(492)], 0))
        self.assertFalse(d.update([self.sample(571.9)], 5))
        alerts = d.update([self.sample(572)], 10)
        self.assertEqual(alerts[0][1], 1)
        self.assertIn('80.00 GiB', alerts[0][2])
        self.assertFalse(d.update([self.sample(580)], 15))
        self.assertTrue(d.update([self.sample(580)], 310))

    def test_missing_stats_pid_reuse_and_exit_reset(self):
        d = m.Detector(virtual_growth=8*m.GIB)
        self.assertFalse(d.update([self.sample(None)], 0))
        self.assertFalse(d.update([self.sample(492)], 5))
        self.assertFalse(d.update([self.sample(None)], 10))
        self.assertTrue(d.update([self.sample(500)], 15))
        self.assertFalse(d.update([self.sample(600, started=2)], 20))
        self.assertFalse(d.update([], 25))
        self.assertFalse(d.tracks)
        self.assertFalse(d.update([self.sample(700, started=2)], 30))

    def test_allowlist_and_baseline_stability_after_drop(self):
        for path in ('/tmp/HydraRenderingService', '', '/Applications/Example.app/Contents/MacOS/Example'):
            d = m.Detector()
            d.update([self.sample(1, path=path)], 0)
            self.assertFalse(d.update([self.sample(1000, path=path)], 5))
        d = m.Detector(virtual_growth=8*m.GIB)
        d.update([self.sample(492)], 0)
        d.update([self.sample(400)], 5)
        self.assertFalse(d.update([self.sample(499)], 10))
        self.assertTrue(d.update([self.sample(500)], 15))

    def test_physical_escalation_not_suppressed_by_virtual_warning(self):
        d = m.Detector()
        d.update([self.sample(492)], 0)
        self.assertEqual(d.update([self.sample(500)], 5)[0][1], 1)
        self.assertEqual(d.update([self.sample(500, footprint=5)], 10)[0][1], 3)


class SystemMemoryTests(unittest.TestCase):
    def test_pressure_requires_consecutive_samples_and_cooldown(self):
        d = m.SystemDetector()
        self.assertFalse(d.update(m.SystemSample(0, 2), 0))
        self.assertTrue(d.update(m.SystemSample(0, 4), 5))
        self.assertFalse(d.update(m.SystemSample(0, 4), 10))
        self.assertTrue(d.update(m.SystemSample(0, 4), 305))

    def test_pressure_escalation_bypasses_only_its_own_cooldown(self):
        d = m.SystemDetector()
        self.assertFalse(d.update(m.SystemSample(0, 2), 0))
        self.assertTrue(d.update(m.SystemSample(0, 2), 5))
        self.assertTrue(d.update(m.SystemSample(0, 4), 10))
        self.assertFalse(d.update(m.SystemSample(0, 4), 15))
        self.assertFalse(d.update(m.SystemSample(0, 1), 20))
        self.assertFalse(d.update(m.SystemSample(0, 2), 25))
        self.assertFalse(d.update(m.SystemSample(0, 2), 30))

    def test_swap_alert_does_not_suppress_pressure_alert(self):
        d = m.SystemDetector()
        d.update(m.SystemSample(0, 1), 0)
        self.assertTrue(d.update(m.SystemSample(m.GIB, 1), 60))
        self.assertFalse(d.update(m.SystemSample(m.GIB, 2), 65))
        self.assertIn('内存压力', d.update(m.SystemSample(m.GIB, 2), 70)[0])

    def test_unavailable_pressure_breaks_sequence_without_claiming_normal(self):
        d = m.SystemDetector()
        d.update(m.SystemSample(None, 2), 0)
        self.assertFalse(d.update(m.SystemSample(), 5))
        self.assertFalse(d.update(m.SystemSample(None, 2), 10))
        self.assertTrue(d.update(m.SystemSample(None, 2), 15))
        reader = m.SystemReader.__new__(m.SystemReader)
        reader.lib = SimpleNamespace(sysctlbyname=Mock(return_value=-1))
        self.assertIsNone(reader.physical_memory())
        self.assertEqual(reader.snapshot(), m.SystemSample())

    def test_net_swap_growth_uses_elapsed_window_despite_jitter(self):
        d = m.SystemDetector()
        self.assertFalse(d.update(m.SystemSample(10*m.GIB, 1), 0))
        self.assertFalse(d.update(m.SystemSample(10*m.GIB, 1), 5.1))
        self.assertFalse(d.update(m.SystemSample(11*m.GIB, 1), 59.9))
        alerts = d.update(m.SystemSample(11*m.GIB, 1), 60.2)
        self.assertEqual(d.swap_growth, m.GIB)
        self.assertIn('净增长 1.00 GiB', alerts[0])
        self.assertFalse(d.update(m.SystemSample(12*m.GIB, 1), 65.3))

    def test_reclaimed_swap_missing_samples_and_sleep_do_not_fake_growth(self):
        d = m.SystemDetector()
        d.update(m.SystemSample(10*m.GIB, 1), 0)
        self.assertFalse(d.update(m.SystemSample(9*m.GIB, 1), 60))
        self.assertEqual(d.swap_growth, 0)
        d.update(m.SystemSample(), 65)
        self.assertFalse(d.update(m.SystemSample(20*m.GIB, 1), 70))
        self.assertIsNone(d.swap_growth)
        self.assertFalse(d.update(m.SystemSample(30*m.GIB, 1), 3600))
        self.assertIsNone(d.swap_growth)

    def test_system_only_alert_emission(self):
        with patch('memory_watch.notify') as notify, patch('memory_watch.logging.Logger') as logger:
            m.emit([], False, logger, ['系统内存压力异常'])
            notify.assert_called_once_with('系统内存压力异常')
            logger.warning.assert_called_once()


class SamplingTests(unittest.TestCase):
    def test_optional_task_info_failure_preserves_footprint_and_rss(self):
        sampler = m.Sampler.__new__(m.Sampler)
        def usage(pid, version, pointer):
            pointer._obj.started = 9
            pointer._obj.footprint = 5*m.GIB
            pointer._obj.resident = 4*m.GIB
            return 0
        sampler.lib = SimpleNamespace(proc_pid_rusage=usage, proc_pidinfo=Mock(return_value=0))
        listing = SimpleNamespace(stdout=f'999999 {VirtualGrowthTests.path}\n')
        with patch('memory_watch.subprocess.run', return_value=listing):
            samples, skipped = sampler.snapshot()
        self.assertEqual(skipped, 0)
        self.assertEqual(samples[0].memory, 5*m.GIB)
        self.assertEqual(samples[0].rss_bytes, 4*m.GIB)
        self.assertIsNone(samples[0].virtual_bytes)

    def test_pid_reuse_or_exit_during_task_info_skips_mixed_metrics(self):
        for second_result in ('reused', 'unavailable'):
            with self.subTest(second_result=second_result):
                sampler = m.Sampler.__new__(m.Sampler)
                calls = 0
                def usage(pid, version, pointer):
                    nonlocal calls
                    calls += 1
                    pointer._obj.started = calls
                    pointer._obj.footprint = 5*m.GIB
                    return -1 if calls == 2 and second_result == 'unavailable' else 0
                sampler.lib = SimpleNamespace(proc_pid_rusage=usage, proc_pidinfo=Mock(return_value=0))
                listing = SimpleNamespace(stdout=f'999999 {VirtualGrowthTests.path}\n')
                with patch('memory_watch.subprocess.run', return_value=listing):
                    samples, skipped = sampler.snapshot()
                self.assertFalse(samples)
                self.assertEqual(skipped, 1)
                self.assertEqual(calls, 2)

    def test_unknown_and_partial_system_stats_stay_unavailable(self):
        reader = m.SystemReader.__new__(m.SystemReader)
        with patch.object(reader, 'read', side_effect=[None, m.ctypes.c_int32(99)]):
            self.assertEqual(reader.snapshot(), m.SystemSample())
        def partial(name, value, length, unused, count):
            length._obj.value = 1
            return 0
        reader.lib = SimpleNamespace(sysctlbyname=partial)
        self.assertIsNone(reader.read('hw.memsize', m.ctypes.c_uint64))


if __name__ == '__main__':
    unittest.main()
