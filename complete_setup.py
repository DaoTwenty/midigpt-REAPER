#!/usr/bin/env python3
"""
Composer's Assistant v2 - Complete Setup Script
Fixed version with proper NumPy constraint handling
"""

import os
import sys
import subprocess
import shutil
import platform
from pathlib import Path

VENV_NAME = ".venv"
PYTHON_MIN_VERSION = (3, 9)
MMM_REPO = "https://github.com/DaoTwenty/MMM.git"
MMM_BRANCH = "python_complete"

def run_command(cmd, capture_output=False, cwd=None):
    """Run command with proper error handling and shell escaping"""
    try:
        if isinstance(cmd, str):
            result = subprocess.run(cmd, shell=True, check=True, 
                                  capture_output=capture_output, text=True, cwd=cwd)
        else:
            result = subprocess.run(cmd, check=True, 
                                  capture_output=capture_output, text=True, cwd=cwd)
        return result
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {cmd}")
        print(f"Error: {e}")
        if capture_output:
            print(f"Output: {e.stdout}")
            print(f"Error: {e.stderr}")
        raise

def check_python():
    """Check for compatible Python version"""
    print("Checking Python version...")
    
    python_commands = ["python3.12", "python3", "python"]
    
    for cmd in python_commands:
        try:
            result = run_command(f"{cmd} --version", capture_output=True)
            version_str = result.stdout.strip()
            
            version_parts = version_str.split()[-1].split('.')
            major, minor = int(version_parts[0]), int(version_parts[1])
                
            if (major, minor) >= PYTHON_MIN_VERSION:
                print(f"Compatible Python found: {version_str}")
                return cmd
        except:
            continue
    
    print(f"Python {PYTHON_MIN_VERSION[0]}.{PYTHON_MIN_VERSION[1]}+ not found")
    print("Install Python 3.9+:")
    print("  macOS: brew install python@3.9")
    print("  Ubuntu: sudo apt install python3.9 python3.9-venv")
    sys.exit(1)

def check_cuda():
    """Check if CUDA is available"""
    try:
        run_command("nvidia-smi", capture_output=True)
        print("CUDA detected")
        return True
    except:
        print("No CUDA detected - using CPU-only PyTorch")
        return False

def install_rust_macos():
    """Install Rust on macOS if not already present"""
    if platform.system() != "Darwin":
        return
    
    print("Checking for Rust installation...")
    
    try:
        result = run_command("rustc --version", capture_output=True)
        print(f"Rust already installed: {result.stdout.strip()}")
        return
    except:
        print("Rust not found, installing...")
    
    print("Installing Rust toolchain...")
    try:
        run_command("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y")
        
        cargo_env = Path.home() / ".cargo/env"
        if cargo_env.exists():
            print("Sourcing Rust environment...")
            os.environ["PATH"] = f"{Path.home() / '.cargo/bin'}:{os.environ.get('PATH', '')}"
        
        result = run_command("rustc --version", capture_output=True)
        print(f"Rust installed successfully: {result.stdout.strip()}")
        
    except Exception as e:
        print(f"Rust installation failed: {e}")
        print("You may need to manually install Rust from https://rustup.rs/")
        print("After installation, restart your terminal and re-run this script.")

def setup_venv(python_cmd):
    """Create virtual environment"""
    venv_path = Path(VENV_NAME)
    
    if venv_path.exists():
        print(f"Virtual environment exists: {VENV_NAME}")
        return
    
    print("Creating virtual environment...")
    run_command(f"{python_cmd} -m venv {VENV_NAME}")
    print(f"Virtual environment created: {VENV_NAME}")

def get_pip_command():
    """Get pip command for the virtual environment"""
    if platform.system() == "Windows":
        return Path(VENV_NAME) / "Scripts" / "pip"
    else:
        return Path(VENV_NAME) / "bin" / "pip"

def get_python_command():
    """Get Python command for the virtual environment"""
    current_dir = Path.cwd()
    if platform.system() == "Windows":
        return str(current_dir / VENV_NAME / "Scripts" / "python")
    else:
        return str(current_dir / VENV_NAME / "bin" / "python")

def install_core_dependencies(has_cuda=False):
    """Install core Python dependencies with proper constraint handling"""
    pip_cmd = str(get_pip_command())
    
    print("Upgrading pip...")
    run_command([pip_cmd, "install", "--upgrade", "pip", "setuptools", "wheel"])
    
    print("Installing core dependencies...")
    
    if has_cuda:
        print("Installing PyTorch with CUDA...")
        run_command([pip_cmd, "install", "torch>=2.0.0", "torchvision", "torchaudio", 
                    "--index-url", "https://download.pytorch.org/whl/cu118"])
    else:
        print("Installing CPU-only PyTorch...")
        run_command([pip_cmd, "install", "torch>=2.0.0", "torchvision", "torchaudio",
                    "--index-url", "https://download.pytorch.org/whl/cpu"])
    
    deps = [
        ("numpy", "numpy==1.26.4"),
        ("protobuf", "protobuf>=4.0.0"), 
        ("pybind11", "pybind11[global]>=2.12.0"),
        ("transformers", "transformers==4.41.0"),
        ("cmake", "cmake>=3.16.0"),
        ("tqdm", "tqdm")
    ]
    
    for name, constraint in deps:
        print(f"Installing {constraint}...")
        run_command([pip_cmd, "install", constraint])

def install_project_requirements():
    """Install project-specific requirements"""
    pip_cmd = str(get_pip_command())
    
    midi_libs = ["mido>=1.1.16", "miditoolkit"]
    
    for lib in midi_libs:
        print(f"Installing {lib}...")
        run_command([pip_cmd, "install", lib])
    
    other_libs = ["portion", "sentencepiece", "matplotlib"]
    
    for lib in other_libs:
        print(f"Installing {lib}...")
        run_command([pip_cmd, "install", lib])

def clone_mmm():
    """Clone MMM repository"""
    if Path("MMM").exists():
        print("MMM repository already exists")
        try:
            result = run_command("git branch --show-current", capture_output=True, cwd="MMM")
            current_branch = result.stdout.strip()
            if current_branch != MMM_BRANCH:
                print(f"Switching from {current_branch} to {MMM_BRANCH} branch...")
                run_command(f"git checkout {MMM_BRANCH}", cwd="MMM")
            else:
                print(f"Already on {MMM_BRANCH} branch")
        except:
            print("Could not determine current branch, proceeding with existing repo")
        return
    
    print(f"Cloning MMM repository ({MMM_BRANCH} branch)...")
    run_command(f"git clone -b {MMM_BRANCH} {MMM_REPO}")
    print(f"MMM repository cloned from {MMM_BRANCH} branch")

def build_mmm():
    """Build and install MMM using pip install"""
    print("Building and installing MMM...")
    
    if not Path("MMM").exists():
        print("MMM directory not found")
        return False
    
    try:
        python_cmd = str(get_python_command())
        run_command(f"{python_cmd} -m pip install .", cwd="MMM")
        
        print("MMM built and installed successfully")
        return True
        
    except Exception as e:
        print(f"MMM install failed: {e}")
        return False

def setup_reaper_integration():
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
    scripts_src = project_root / "src" / "Scripts"
    effects_src = project_root / "src" / "Effects"

    print(f"Linking:\n    - {scripts_src}\n    - {effects_src}")
    
    scripts_dst = reaper_path / "Scripts/composers_assistant_v2"
    effects_dst = reaper_path / "Effects/composers_assistant_v2"
    
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

def download_models():
    """Download required models if not present"""
    models_dir = Path("models")
    if not models_dir.exists():
        models_dir.mkdir()
    
    if any(models_dir.glob("*.bin")) or any(models_dir.glob("*.pth")):
        print("Models already present")
        return
    
    print("Model download would occur here - implement as needed")

def verify_installation():
    """Verify all components are working"""
    print("\nVerifying installation...")
    
    python_cmd = str(get_python_command())
    
    test_imports = [
        ("import torch", "PyTorch"),
        ("import numpy", "NumPy"), 
        ("import transformers", "Transformers")
    ]
    
    for test_cmd, name in test_imports:
        try:
            run_command([python_cmd, "-c", test_cmd], capture_output=True)
            print(f"  ✓ {name}")
        except:
            print(f"  ✗ {name}")
    
    try:
        run_command([python_cmd, "-c", "import mmm; print('MMM: Ready')"], 
                   capture_output=True)
        print("  ✓ MMM import (installed)")
    except:
        print("  ✗ MMM import - requires manual completion")

def print_completion_message():
    """Print completion message and next steps"""
    activate_cmd = f"source {VENV_NAME}/bin/activate"
    if platform.system() == "Windows":
        activate_cmd = f"{VENV_NAME}\\Scripts\\activate"
    
    print("\n" + "="*50)
    print("Setup Complete!")
    print("="*50)
    print(f"\nTo activate the environment: {activate_cmd}")
    print("\nNext steps:")
    print("1. Start the server: python start_server.py start")
    print("2. Open REAPER and load Composer's Assistant scripts")
    print("3. Begin composing with AI assistance!")
    
    print(f"\nTo verify your virtual environment is working:")
    print(f"  {activate_cmd}")
    print(f"  python -c \"import sys; print(sys.executable)\"")
    print(f"  python -c \"import numpy; print('NumPy:', numpy.__version__)\"")

def main():
    print("Composer's Assistant v2 - Complete Setup")
    print("=" * 50)
    
    try:
        python_cmd = check_python()
        has_cuda = check_cuda()
        
        setup_venv(python_cmd)
        install_core_dependencies(has_cuda)
        install_project_requirements()       

        clone_mmm()
        midi_success = build_mmm()
        
        setup_reaper_integration()
        download_models()
        verify_installation()
        print_completion_message()
        
        if not midi_success:
            print("\nNote: MMM build failed")
            sys.exit(1)
            
    except KeyboardInterrupt:
        print("\nSetup interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\nSetup failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()