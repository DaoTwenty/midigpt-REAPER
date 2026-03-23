import platform
from pathlib import Path

def main():
    """Setup REAPER integration"""
    if platform.system() == "Darwin":
        reaper_path = Path.home() / "Library/Application Support/REAPER"
    elif platform.system() == "Windows":
        reaper_path = Path.home() / "AppData/Roaming/REAPER"
    else:
        reaper_path = Path.home() / ".config/REAPER"
    
    if not reaper_path.exists():
        print(f"REAPER not found at {reaper_path}")
        return
    
    print(f"Setting up REAPER integration at: {reaper_path}")
    
    project_root = Path.cwd()
    scripts_src = project_root / "src" / "Scripts" / "MMM"
    effects_src = project_root / "src" / "Effects" / "MMM"

    print(f"Linking:\n    - {scripts_src}\n    - {effects_src}")
    
    scripts_dst = reaper_path / "Scripts" / "MMM"
    effects_dst = reaper_path / "Effects" / "MMM"
    
    if scripts_src.exists():
        if scripts_dst.exists():
            scripts_dst.unlink()
        scripts_dst.symlink_to(scripts_src)
        print(f"Scripts symlinked: {scripts_dst}")
    
    if effects_src.exists():
        if effects_dst.exists():
            effects_dst.unlink()
        effects_dst.symlink_to(effects_src)
        print(f"Effects symlinked: {effects_dst}")

if __name__ == "__main__":
    main()