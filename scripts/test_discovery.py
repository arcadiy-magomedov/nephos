import pathlib
import runpy
import unittest

advertisement = runpy.run_path(str(pathlib.Path(__file__).with_name("advertise-server.py")))["advertisement"]


class DiscoveryTests(unittest.TestCase):
    def test_bonjour_and_avahi_publish_same_version_and_canonical_url(self):
        for platform, executable in (("darwin", "dns-sd"), ("linux", "avahi-publish-service")):
            command = advertisement("https://Photos.local:18443/", "Nephos", platform)
            self.assertEqual(executable, command[0])
            self.assertIn("_nephos._tcp", command)
            self.assertEqual(["18443", "v=1", "url=https://photos.local:18443"], command[-3:])
        self.assertEqual("443", advertisement("https://photos.example.net", "Nephos", "darwin")[-3])
        self.assertIn("url=https://[fd00::1]:8443", advertisement("https://[fd00::1]:8443", "Nephos", "linux"))

    def test_no_credentials_loopback_or_oversized_txt_entries(self):
        for address in (
            "http://photos.local",
            "https://user:password@photos.local",
            "https://localhost",
            "https://localhost.",
            "https://127.0.0.1",
            "https://[::1]",
            "https://0.0.0.0",
            "https://[::]",
            "https://photos.local:0",
            "https://photos.local:65536",
            "https://photos.local?token=x",
            "https://photos.local?",
            "https://photos.local#",
            "https://photos.local\n",
            "https://photos.local/" + "x" * 252,
        ):
            with self.subTest(address=address), self.assertRaises(ValueError):
                advertisement(address, "Nephos", "darwin")
        for name in ("", " ", "x" * 64, "bad\nname", "\U0001f600" * 16):
            with self.subTest(name=name), self.assertRaises(ValueError):
                advertisement("https://photos.local", name, "darwin")
