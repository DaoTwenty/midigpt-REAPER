"""Mutable dashboard state kept separate from rendering code."""

from .constants import DEFAULT_GLOBAL_SETTINGS, DEFAULT_TRACK_SETTINGS


class DashboardState:
    def __init__(self):
        self.global_settings = dict(DEFAULT_GLOBAL_SETTINGS)
        self.track_settings = {}
        self.expanded_track_guids = set()

    def track(self, guid):
        return self.track_settings.setdefault(guid, dict(DEFAULT_TRACK_SETTINGS))

    def forget_missing_tracks(self, visible_guids):
        self.expanded_track_guids.intersection_update(visible_guids)
        self.track_settings = {
            guid: settings
            for guid, settings in self.track_settings.items()
            if guid in visible_guids
        }
