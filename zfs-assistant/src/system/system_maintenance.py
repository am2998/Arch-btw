#!/usr/bin/env python3
# ZFS Assistant - System Maintenance Operations
# Author: GitHub Copilot

import subprocess
from typing import Tuple, List, Dict, Any

# Handle imports for both relative and direct execution
try:
    from ..utils.logger import (
        OperationType, LogLevel, get_logger,
        log_info, log_error, log_success, log_warning
    )
except ImportError:
    import sys
    import os
    current_dir = os.path.dirname(os.path.abspath(__file__))
    parent_dir = os.path.dirname(current_dir)
    if parent_dir not in sys.path:
        sys.path.insert(0, parent_dir)
    
    from utils.logger import (
        OperationType, LogLevel, get_logger,
        log_info, log_error, log_success, log_warning
    )


class SystemMaintenance:
    """System maintenance operations including package management and system updates."""
    
    def __init__(self, privilege_manager, config):
        self.logger = get_logger()
        self.privilege_manager = privilege_manager
        self.config = config

    def update_config(self, config: dict):
        """Update configuration reference when settings are saved"""
        self.config = config

    def create_system_update_snapshot(self, snapshot_type: str = "sysupdate") -> Tuple[bool, str]:
        """
        Create a pre-update snapshot for all configured datasets in one batch.

        Args:
            snapshot_type: Label used in snapshot naming.

        Returns:
            (success, message) tuple
        """
        try:
            datasets = self.config.get("datasets", [])
            if not datasets:
                return False, "No datasets configured for system update snapshot"

            safe_type = (snapshot_type or "sysupdate").strip().replace(" ", "-")
            safe_type = "".join(ch for ch in safe_type if ch.isalnum() or ch in ("-", "_"))
            if not safe_type:
                safe_type = "sysupdate"

            snapshot_name = f"zfs-assistant-{safe_type}-{self._get_timestamp()}"
            from .zfs_core import ZFSCore
            zfs_core = ZFSCore(self.privilege_manager, self.config)
            return zfs_core.create_batch_snapshots(datasets, snapshot_name)
        except Exception as e:
            return False, f"Error creating system update snapshot: {str(e)}"
    
    def run_system_update(self) -> Tuple[bool, str]:
        """
        Run system update using pacman -Syu.
        Uses streamlined logging only if part of a scheduled operation.
        
        Returns:
            (success, message) tuple
        """
        try:
            # Check if this is part of a scheduled operation
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.INFO, "Starting system update")
            
            success, result = self.privilege_manager.run_privileged_command([
                'pacman', '-Syu', '--noconfirm'
            ])
            
            if not success:
                error_msg = f"System update failed: {result}"
                if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                    self.logger.log_essential_message(LogLevel.ERROR, error_msg)
                return False, error_msg
            
            success_msg = "System update completed successfully"
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.SUCCESS, success_msg)
            return True, success_msg
            
        except Exception as e:
            error_msg = f"Error during system update: {str(e)}"
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.ERROR, error_msg)
            return False, error_msg
    
    def clean_package_cache(self) -> Tuple[bool, str]:
        """
        Clean package cache using pacman -Scc.
        Uses streamlined logging only if part of a scheduled operation.
        
        Returns:
            (success, message) tuple
        """
        try:
            # Check if this is part of a scheduled operation
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.INFO, "Starting package cache cleanup")
            
            success, result = self.privilege_manager.run_privileged_command([
                'pacman', '-Scc', '--noconfirm'
            ])
            
            if not success:
                error_msg = f"Cache cleaning failed: {result}"
                if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                    self.logger.log_essential_message(LogLevel.ERROR, error_msg)
                return False, error_msg
            
            success_msg = "Package cache cleaned successfully"
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.SUCCESS, success_msg)
            return True, success_msg
            
        except Exception as e:
            error_msg = f"Error during cache cleaning: {str(e)}"
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.ERROR, error_msg)
            return False, error_msg

    def update_flatpak_packages(self) -> Tuple[bool, str]:
        """
        Update flatpak packages.
        Uses streamlined logging only if part of a scheduled operation.
        
        Returns:
            (success, message) tuple
        """
        try:
            # Check if this is part of a scheduled operation
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.INFO, "Starting flatpak update")
            
            success, result = self.privilege_manager.run_privileged_command([
                'flatpak', 'update', '-y'
            ])
            
            if not success:
                error_msg = f"Flatpak update failed: {result}"
                if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                    self.logger.log_essential_message(LogLevel.ERROR, error_msg)
                return False, error_msg
            
            success_msg = "Flatpak packages updated successfully"
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.SUCCESS, success_msg)
            return True, success_msg
            
        except Exception as e:
            error_msg = f"Error during flatpak update: {str(e)}"
            if hasattr(self.logger, 'current_operation') and self.logger.current_operation:
                self.logger.log_essential_message(LogLevel.ERROR, error_msg)
            return False, error_msg
    
    def remove_orphaned_packages(self) -> Tuple[bool, str]:
        """
        Remove orphaned packages using pacman -Qtdq | pacman -Rns.
        
        Returns:
            (success, message) tuple
        """
        try:
            log_info("Starting orphaned package removal")
            
            # First, get orphaned packages
            result = subprocess.run(['pacman', '-Qtdq'], 
                                  capture_output=True, text=True, check=False)
            
            if result.returncode != 0 or not result.stdout.strip():
                success_msg = "No orphaned packages found"
                log_success(success_msg)
                return True, success_msg
            
            orphaned_packages = result.stdout.strip().split('\n')
            if not orphaned_packages or orphaned_packages == ['']:
                success_msg = "No orphaned packages found"
                log_success(success_msg)
                return True, success_msg
            
            log_info(f"Found {len(orphaned_packages)} orphaned packages", {
                'orphaned_packages': orphaned_packages
            })
            
            # Remove orphaned packages
            cmd = ['pacman', '-Rns', '--noconfirm'] + orphaned_packages
            success, result = self.privilege_manager.run_privileged_command(cmd)
            
            if not success:
                error_msg = f"Failed to remove orphaned packages: {result}"
                log_error(error_msg, {'command_output': result})
                self.logger.log_system_command(cmd, False, error=result)
                return False, error_msg
            
            success_msg = f"Removed {len(orphaned_packages)} orphaned package(s)"
            log_success(success_msg, {'orphaned_packages': orphaned_packages})
            self.logger.log_system_command(cmd, True)
            return True, success_msg
            
        except Exception as e:
            error_msg = f"Error removing orphaned packages: {str(e)}"
            log_error(error_msg, {'exception': str(e)})
            return False, error_msg
    
    def perform_system_maintenance(self, create_snapshot_before: bool = True, 
                                 run_update: bool = True, clean_cache: bool = True, 
                                 remove_orphans: bool = True, update_flatpak: bool = True,
                                 datasets: List[str] = None) -> Tuple[bool, str]:
        """
        Perform comprehensive system maintenance including snapshots, updates, and cleanup.
        Uses streamlined logging for essential scheduled operations.
        
        Args:
            create_snapshot_before: Whether to create snapshots before updates
            run_update: Whether to run system update
            clean_cache: Whether to clean package cache
            remove_orphans: Whether to remove orphaned packages
            update_flatpak: Whether to update flatpak packages
            datasets: List of datasets to snapshot (if create_snapshot_before is True)
            
        Returns:
            (success, message) tuple with detailed results
        """
        try:
            # Start scheduled operation with streamlined logging
            self.logger.start_scheduled_operation(
                OperationType.SYSTEM_MAINTENANCE, 
                "System Maintenance - Updates and Cleanup"
            )
            
            results = []
            overall_success = True
            
            # Step 1: Create snapshots before maintenance using batch operation
            if create_snapshot_before and datasets:
                self.logger.log_essential_message(LogLevel.INFO, "Creating pre-maintenance snapshots in batch")
                snapshot_name = f"pre-maintenance-{self._get_timestamp()}"
                
                from .zfs_core import ZFSCore
                zfs_core = ZFSCore(self.privilege_manager, self.config)
                success, message = zfs_core.create_batch_snapshots(datasets, snapshot_name)
                results.append(f"Pre-maintenance snapshots: {message}")
                if not success:
                    overall_success = False
            
            # Batch all pacman operations to reduce pkexec prompts
            pacman_commands = []
            command_descriptions = []
            
            # Step 2: Build system update command
            if run_update:
                pacman_commands.append(['pacman', '-Syu', '--noconfirm'])
                command_descriptions.append("System update")
            
            # Step 3: Build cache cleanup command  
            if clean_cache:
                pacman_commands.append(['pacman', '-Scc', '--noconfirm'])
                command_descriptions.append("Cache cleanup")
            
            # Step 4: Build orphan removal command
            if remove_orphans:
                try:
                    # First check for orphaned packages
                    result = subprocess.run(['pacman', '-Qdtq'], 
                                          capture_output=True, text=True, check=False)
                    
                    if result.returncode == 0 and result.stdout.strip():
                        orphaned_packages = result.stdout.strip().split('\n')
                        self.logger.log_essential_message(LogLevel.INFO, f"Found {len(orphaned_packages)} orphaned packages")
                        pacman_commands.append(['pacman', '-Rns', '--noconfirm'] + orphaned_packages)
                        command_descriptions.append(f"Remove {len(orphaned_packages)} orphaned packages")
                    else:
                        results.append("Orphan removal: No orphaned packages found")
                        self.logger.log_essential_message(LogLevel.INFO, "No orphaned packages found")
                except Exception as e:
                    self.logger.log_essential_message(LogLevel.ERROR, f"Could not check for orphaned packages: {str(e)}")
                    results.append(f"Orphan removal: Failed to check - {str(e)}")
            
            # Execute all pacman commands in batch if any exist
            if pacman_commands:
                self.logger.log_essential_message(LogLevel.INFO, f"Executing {len(pacman_commands)} maintenance commands in batch")
                success, batch_result = self.privilege_manager.run_batch_privileged_commands(pacman_commands)
                
                if success:
                    for description in command_descriptions:
                        results.append(f"{description}: Success")
                        self.logger.log_essential_message(LogLevel.SUCCESS, f"Maintenance operation completed: {description}")
                else:
                    # If batch fails, mark all operations as failed
                    for description in command_descriptions:
                        results.append(f"{description}: Failed - {batch_result}")
                        self.logger.log_essential_message(LogLevel.ERROR, f"Maintenance operation failed: {description} - {batch_result}")
                    overall_success = False
            
            # Step 5: Update flatpak packages separately
            if update_flatpak:
                self.logger.log_essential_message(LogLevel.INFO, "Updating flatpak packages")
                try:
                    success, result = self.privilege_manager.run_privileged_command(['flatpak', 'update', '-y'])
                    if success:
                        results.append("Flatpak update: Success")
                        self.logger.log_essential_message(LogLevel.SUCCESS, "Flatpak packages updated successfully")
                    else:
                        results.append(f"Flatpak update: Failed - {result}")
                        self.logger.log_essential_message(LogLevel.ERROR, f"Flatpak update failed: {result}")
                        overall_success = False
                except Exception as e:
                    results.append(f"Flatpak update: Failed - {str(e)}")
                    self.logger.log_essential_message(LogLevel.ERROR, f"Flatpak update error: {str(e)}")
                    overall_success = False
            
            # Compile final results
            final_message = "System maintenance completed. " + "; ".join(results)
            
            if overall_success:
                self.logger.log_essential_message(LogLevel.SUCCESS, "System maintenance completed successfully")
                self.logger.end_scheduled_operation(True, final_message)
                return True, final_message
            else:
                self.logger.log_essential_message(LogLevel.ERROR, "System maintenance completed with some errors")
                self.logger.end_scheduled_operation(False, final_message)
                return False, final_message
            
        except Exception as e:
            error_msg = f"Error during system maintenance: {str(e)}"
            self.logger.log_essential_message(LogLevel.ERROR, error_msg)
            self.logger.end_scheduled_operation(False, error_msg)
            return False, error_msg
    
    def optimize_system(self) -> Tuple[bool, str]:
        """
        Perform system optimization tasks.
        
        Returns:
            (success, message) tuple
        """
        try:
            log_info("Starting system optimization")
            
            optimization_commands = [
                (['pacman', '-Sc', '--noconfirm'], "Clean package cache (partial)"),
                (['sync'], "Sync filesystem buffers")
            ]
            
            # Run optimization operations
            results = []
            overall_success = True
            
            # Separate privileged and non-privileged commands for batch execution
            privileged_commands = []
            privileged_descriptions = []
            
            for command, description in optimization_commands:
                try:
                    if command[0] in ['pacman']:
                        # Collect privileged commands for batch execution
                        privileged_commands.append(command)
                        privileged_descriptions.append(description)
                    else:
                        # Run regular user commands immediately
                        log_info(f"Running optimization: {description}")
                        result = subprocess.run(command, check=True, capture_output=True, text=True)
                        results.append(f"{description}: Success")
                        log_success(f"Optimization completed: {description}")
                        
                except subprocess.CalledProcessError as e:
                    error_msg = f"{description}: Failed - {e.stderr.strip() if e.stderr else str(e)}"
                    results.append(error_msg)
                    log_error(f"Optimization failed: {error_msg}")
                    overall_success = False
                except Exception as e:
                    error_msg = f"{description}: Failed - {str(e)}"
                    results.append(error_msg)
                    log_error(f"Optimization failed: {error_msg}")
                    overall_success = False
            
            # Execute all privileged commands in batch if any exist
            if privileged_commands:
                log_info(f"Executing {len(privileged_commands)} privileged optimization commands in batch")
                success, batch_result = self.privilege_manager.run_batch_privileged_commands(privileged_commands)
                
                if success:
                    for description in privileged_descriptions:
                        results.append(f"{description}: Success")
                        log_success(f"Optimization completed: {description}")
                else:
                    for description in privileged_descriptions:
                        results.append(f"{description}: Failed - {batch_result}")
                        log_error(f"Optimization failed: {description} - {batch_result}")
                    overall_success = False
            
            final_message = "System optimization completed. " + "; ".join(results)
            
            if overall_success:
                log_success("System optimization completed successfully")
                return True, final_message
            else:
                log_warning("System optimization completed with some errors")
                return False, final_message
            
        except Exception as e:
            error_msg = f"Error during system optimization: {str(e)}"
            log_error(error_msg, {'exception': str(e)})
            return False, error_msg
    
    def check_system_health(self) -> Tuple[bool, Dict[str, Any]]:
        """
        Check system health and return status information.
        
        Returns:
            (success, health_info) tuple
        """
        try:
            log_info("Checking system health")
            
            health_info = {
                'zfs_pools': [],
                'disk_usage': {},
                'package_updates': 0,
                'orphaned_packages': 0
            }
            
            # Check ZFS pool status
            try:
                result = subprocess.run(['zpool', 'status'], 
                                      capture_output=True, text=True, check=True)
                # Parse zpool status output for health information
                health_info['zfs_pools'] = self._parse_zpool_status(result.stdout)
            except subprocess.CalledProcessError:
                health_info['zfs_pools'] = ["Error getting ZFS pool status"]
            
            # Check available package updates
            try:
                result = subprocess.run(['pacman', '-Qu'], 
                                      capture_output=True, text=True, check=False)
                if result.returncode == 0:
                    updates = [line for line in result.stdout.strip().split('\n') if line.strip()]
                    health_info['package_updates'] = len(updates)
            except:
                health_info['package_updates'] = -1  # Error checking
            
            # Check orphaned packages
            try:
                result = subprocess.run(['pacman', '-Qtdq'], 
                                      capture_output=True, text=True, check=False)
                if result.returncode == 0 and result.stdout.strip():
                    orphans = [line for line in result.stdout.strip().split('\n') if line.strip()]
                    health_info['orphaned_packages'] = len(orphans)
            except:
                health_info['orphaned_packages'] = -1  # Error checking
            
            # Check disk usage
            try:
                result = subprocess.run(['df', '-h', '/'], 
                                      capture_output=True, text=True, check=True)
                lines = result.stdout.strip().split('\n')
                if len(lines) > 1:
                    parts = lines[1].split()
                    health_info['disk_usage'] = {
                        'total': parts[1] if len(parts) > 1 else 'Unknown',
                        'used': parts[2] if len(parts) > 2 else 'Unknown',
                        'available': parts[3] if len(parts) > 3 else 'Unknown',
                        'usage_percent': parts[4] if len(parts) > 4 else 'Unknown'
                    }
            except:
                health_info['disk_usage'] = {'error': 'Unable to check disk usage'}
            
            log_success("System health check completed")
            return True, health_info
            
        except Exception as e:
            error_msg = f"Error checking system health: {str(e)}"
            log_error(error_msg, {'exception': str(e)})
            return False, {'error': error_msg}
    
    def _parse_zpool_status(self, status_output: str) -> List[str]:
        """Parse zpool status output to extract health information."""
        try:
            pools = []
            lines = status_output.split('\n')
            current_pool = None
            
            for line in lines:
                line = line.strip()
                if line.startswith('pool:'):
                    current_pool = line.split(':', 1)[1].strip()
                elif line.startswith('state:') and current_pool:
                    state = line.split(':', 1)[1].strip()
                    pools.append(f"{current_pool}: {state}")
                    current_pool = None
            
            return pools if pools else ["No ZFS pools found"]
            
        except Exception:
            return ["Error parsing ZFS pool status"]
    
    def _get_timestamp(self) -> str:
        """Get current timestamp for naming."""
        import datetime
        return datetime.datetime.now().strftime("%Y%m%d-%H%M")
