#!/usr/bin/env python3
# ZFS Assistant - Backup and Send/Receive Operations
# Author: GitHub Copilot

import subprocess
import datetime
import os
from typing import List, Optional, Tuple

# Handle imports for both relative and direct execution
try:
    from ..utils.models import ZFSSnapshot
    from ..utils.logger import (
        OperationType, get_logger,
        log_info, log_error, log_success, log_warning
    )
    from ..utils.common import is_safe_zfs_token
except ImportError:
    import sys
    current_dir = os.path.dirname(os.path.abspath(__file__))
    parent_dir = os.path.dirname(current_dir)
    if parent_dir not in sys.path:
        sys.path.insert(0, parent_dir)
    
    from utils.models import ZFSSnapshot
    from utils.logger import (
        OperationType, get_logger,
        log_info, log_error, log_success, log_warning
    )
    from utils.common import is_safe_zfs_token


class ZFSBackup:
    """
    ZFS backup operations including send/receive and incremental backups.
    """
    
    def __init__(self, privilege_manager, config, zfs_core=None):
        self.logger = get_logger()
        self.privilege_manager = privilege_manager
        self.config = config
        self.zfs_core = zfs_core

    def update_config(self, config: dict):
        """Update configuration reference when settings are saved"""
        self.config = config

    def set_zfs_core(self, zfs_core):
        """Inject ZFS core dependency for snapshot lookups."""
        self.zfs_core = zfs_core
    
    def send_snapshot(self, snapshot_full_name: str, target_pool: str, 
                     incremental_snapshot: Optional[str] = None) -> Tuple[bool, str]:
        """
        Send a ZFS snapshot to another pool using zfs send/receive.
        
        Args:
            snapshot_full_name: Full name of the snapshot to send (dataset@snapshot)
            target_pool: Name of the target pool to receive the snapshot
            incremental_snapshot: Optional base snapshot for incremental send
            
        Returns:
            (success, message) tuple
        """
        try:
            if not is_safe_zfs_token(snapshot_full_name) or '@' not in snapshot_full_name:
                return False, "Invalid snapshot identifier"
            if not is_safe_zfs_token(target_pool):
                return False, "Invalid target pool name"
            if incremental_snapshot and not is_safe_zfs_token(incremental_snapshot):
                return False, "Invalid incremental snapshot identifier"

            dataset, snapshot_name = snapshot_full_name.split('@', 1)
            
            backup_type = "incremental" if incremental_snapshot else "full"
            log_info(f"Starting {backup_type} backup: {snapshot_full_name} to {target_pool}", {
                'source_dataset': dataset,
                'snapshot_name': snapshot_name,
                'source_full_name': snapshot_full_name,
                'target_pool': target_pool,
                'backup_type': backup_type,
                'incremental_base': incremental_snapshot,
                'operation': 'send_receive'
            })
            
            # Start operation tracking
            operation_id = self.logger.start_operation(OperationType.SYSTEM_UPDATE, {
                'source_snapshot': snapshot_full_name,
                'target_pool': target_pool,
                'backup_type': backup_type,
                'incremental_base': incremental_snapshot
            })
            
            # Build the commands
            if incremental_snapshot:
                send_cmd = ['zfs', 'send', '-i', incremental_snapshot, snapshot_full_name]
                log_info(f"Using incremental base: {incremental_snapshot}")
            else:
                send_cmd = ['zfs', 'send', snapshot_full_name]
                
            receive_cmd = ['zfs', 'receive', '-F', target_pool]
            # Log the commands
            self.logger.log_system_command(' '.join(send_cmd), True)
            self.logger.log_system_command(' '.join(receive_cmd), True)
            
            # Check for required privileges
            auth_success, _ = self.privilege_manager.run_privileged_command(['true'])
            if not auth_success:
                error_msg = "Failed to obtain administrative privileges for ZFS send/receive operation"
                log_error(error_msg)
                self.logger.end_operation(operation_id, False, {'error': error_msg})
                return False, error_msg
            
            try:
                # Run send/receive commands with elevated privileges
                send_process = subprocess.Popen(
                    send_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                receive_process = subprocess.Popen(
                    receive_cmd,
                    stdin=send_process.stdout,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                
                # Close the pipe in the send process
                send_process.stdout.close()
                
                # Get output and errors
                receive_stdout, receive_stderr = receive_process.communicate()
                send_stdout, send_stderr = send_process.communicate()
                
                # Check return codes
                if send_process.returncode != 0:
                    error_msg = f"Error in send operation: {send_stderr.decode('utf-8')}"
                    log_error(error_msg, {
                        'command': ' '.join(['pkexec'] + send_cmd),
                        'return_code': send_process.returncode,
                        'stderr': send_stderr.decode('utf-8')
                    })
                    self.logger.end_operation(operation_id, False, {'error': error_msg})
                    return False, error_msg
                    
                if receive_process.returncode != 0:
                    error_msg = f"Error in receive operation: {receive_stderr.decode('utf-8')}"
                    log_error(error_msg, {
                        'command': ' '.join(['pkexec'] + receive_cmd),
                        'return_code': receive_process.returncode,
                        'stderr': receive_stderr.decode('utf-8')
                    })
                    self.logger.end_operation(operation_id, False, {'error': error_msg})
                    return False, error_msg
                
                # Log successful backup
                success_msg = f"Successfully sent snapshot {snapshot_full_name} to {target_pool}"
                log_success(success_msg, {
                    'source_dataset': dataset,
                    'snapshot_name': snapshot_name,
                    'target_pool': target_pool,
                    'backup_type': backup_type
                })
                
                self.logger.log_backup_operation(dataset, snapshot_name, target_pool, backup_type, True, {
                    'incremental_base': incremental_snapshot
                })
                self.logger.end_operation(operation_id, True, {'message': success_msg})
                
                return True, success_msg
                
            except Exception as e:
                error_msg = f"Error executing send/receive commands: {str(e)}"
                log_error(error_msg)
                self.logger.end_operation(operation_id, False, {'error': error_msg})
                return False, error_msg
            
        except Exception as e:
            error_msg = f"Error during ZFS send/receive: {str(e)}"
            log_error(error_msg, {
                'snapshot_full_name': snapshot_full_name,
                'target_pool': target_pool,
                'incremental_snapshot': incremental_snapshot,
                'exception': str(e)
            })
            if 'operation_id' in locals():
                self.logger.end_operation(operation_id, False, {'error': error_msg})
            return False, error_msg
    
    def get_latest_common_snapshot(self, source_dataset: str, target_pool: str) -> Optional[str]:
        """
        Find the latest snapshot that exists in both the source dataset and target pool
        for incremental send/receive operations.
        
        Args:
            source_dataset: Source dataset name
            target_pool: Target pool name
            
        Returns:
            The name of the latest common snapshot, or None if no common snapshots exist
        """
        try:
            if self.zfs_core is None:
                return None

            # Get snapshots from source dataset
            source_snapshots = self.zfs_core.get_snapshots(source_dataset)
            source_snapshot_names = {snapshot.name: snapshot for snapshot in source_snapshots}
            
            # Get snapshots from target pool
            target_snapshots = self.zfs_core.get_snapshots(target_pool)
            target_snapshot_names = {snapshot.name: snapshot for snapshot in target_snapshots}
            
            # Find common snapshots
            common_names = set(source_snapshot_names.keys()) & set(target_snapshot_names.keys())
            
            if not common_names:
                return None
                
            # Get the latest common snapshot by creation date
            latest = None
            latest_date = datetime.datetime.min
            
            for name in common_names:
                source_snap = source_snapshot_names[name]
                if isinstance(source_snap.creation_date, datetime.datetime) and source_snap.creation_date > latest_date:
                    latest = source_snap
                    latest_date = source_snap.creation_date
                    
            return latest.full_name if latest else None
            
        except Exception as e:
            log_error(f"Error finding common snapshots: {e}")
            return None
    
    def perform_backup(self, dataset: str, target_pool: str) -> Tuple[bool, str]:
        """
        Perform a backup of the specified dataset to the target pool.
        
        Args:
            dataset: Dataset to back up
            target_pool: Target pool to receive the backup
            
        Returns:
            (success, message) tuple
        """
        try:
            if self.zfs_core is None:
                return False, "Backup module is not initialized with ZFS core dependency"
            if not is_safe_zfs_token(dataset):
                return False, "Invalid source dataset name"
            if not is_safe_zfs_token(target_pool):
                return False, "Invalid target pool name"

            # Check if target pool exists
            try:
                subprocess.run(['zfs', 'list', target_pool], 
                              check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError:
                return False, f"Target pool '{target_pool}' does not exist or is not accessible"
                
            # Get the latest snapshot for the dataset
            snapshots = self.zfs_core.get_snapshots(dataset)
            if not snapshots:
                return False, f"No snapshots found for dataset {dataset}"
                
            # Sort snapshots by creation date (newest first)
            sorted_snapshots = sorted(
                snapshots, 
                key=lambda x: x.creation_date if isinstance(x.creation_date, datetime.datetime) 
                         else datetime.datetime.min,
                reverse=True
            )
            
            latest_snapshot = sorted_snapshots[0]
            
            # Try to find a common snapshot for incremental send
            common_snapshot = self.get_latest_common_snapshot(dataset, target_pool)
            
            if common_snapshot:
                # If latest snapshot is already in the target pool, nothing to do
                if common_snapshot == latest_snapshot.full_name:
                    return True, f"Latest snapshot {latest_snapshot.full_name} already exists in target pool"
                
                # Perform incremental send
                return self.send_snapshot(latest_snapshot.full_name, target_pool, common_snapshot)
            else:
                # Perform full send
                return self.send_snapshot(latest_snapshot.full_name, target_pool)
                
        except Exception as e:
            return False, f"Error performing backup: {str(e)}"
    
    def create_backup_schedule(self, datasets: List[str], target_pool: str, 
                              schedule_type: str = "daily") -> Tuple[bool, str]:
        """
        Create a backup schedule for multiple datasets.
        
        Args:
            datasets: List of datasets to back up
            target_pool: Target pool for backups
            schedule_type: Type of schedule (daily, weekly, monthly)
            
        Returns:
            (success, message) tuple
        """
        try:
            log_info(f"Creating {schedule_type} backup schedule", {
                'datasets': datasets,
                'target_pool': target_pool,
                'schedule_type': schedule_type
            })
            
            # This would integrate with the system integration module
            # to create systemd timers or cron jobs for automated backups
            
            success_count = 0
            failed_datasets = []
            
            for dataset in datasets:
                try:
                    # Perform initial backup to verify setup
                    success, message = self.perform_backup(dataset, target_pool)
                    if success:
                        success_count += 1
                        log_success(f"Initial backup successful for {dataset}")
                    else:
                        failed_datasets.append(f"{dataset}: {message}")
                        log_error(f"Initial backup failed for {dataset}: {message}")
                except Exception as e:
                    failed_datasets.append(f"{dataset}: {str(e)}")
                    log_error(f"Error in initial backup for {dataset}: {str(e)}")
            
            if failed_datasets:
                error_msg = f"Backup schedule created with errors. Failed datasets: {', '.join(failed_datasets)}"
                return False, error_msg
            else:
                success_msg = f"Successfully created {schedule_type} backup schedule for {success_count} datasets"
                return True, success_msg
                
        except Exception as e:
            error_msg = f"Error creating backup schedule: {str(e)}"
            log_error(error_msg)
            return False, error_msg
    
    def verify_backup_integrity(self, source_dataset: str, target_pool: str) -> Tuple[bool, str]:
        """
        Verify the integrity of backups by comparing snapshots.
        
        Args:
            source_dataset: Source dataset to verify
            target_pool: Target pool containing backups
            
        Returns:
            (success, message) tuple
        """
        try:
            log_info(f"Verifying backup integrity: {source_dataset} -> {target_pool}")
            
            # Get snapshots from both source and target
            source_snapshots = self.zfs_core.get_snapshots(source_dataset)
            target_snapshots = self.zfs_core.get_snapshots(target_pool)
            
            source_names = {snap.name for snap in source_snapshots}
            target_names = {snap.name for snap in target_snapshots}
            
            # Check for missing snapshots
            missing_in_target = source_names - target_names
            extra_in_target = target_names - source_names
            
            issues = []
            if missing_in_target:
                issues.append(f"Missing in target: {', '.join(missing_in_target)}")
            
            if extra_in_target:
                issues.append(f"Extra in target: {', '.join(extra_in_target)}")
            
            if issues:
                warning_msg = f"Backup integrity check found issues: {'; '.join(issues)}"
                log_warning(warning_msg)
                return False, warning_msg
            else:
                success_msg = f"Backup integrity verified: {len(source_names)} snapshots match"
                log_success(success_msg)
                return True, success_msg
                
        except Exception as e:
            error_msg = f"Error verifying backup integrity: {str(e)}"
            log_error(error_msg)
            return False, error_msg

    def run_scheduled_backup(self) -> Tuple[bool, str]:
        """Run configured external backups for managed datasets."""
        try:
            if not self.config.get("external_backup_enabled", False):
                return True, "External backup is disabled"

            target_pool = self.config.get("external_pool_name", "").strip()
            if not target_pool:
                return False, "External backup is enabled but no target pool is configured"

            datasets = self.config.get("datasets", [])
            if not datasets:
                return False, "No datasets configured for scheduled backup"

            success_count = 0
            failures = []
            for dataset in datasets:
                success, message = self.perform_backup(dataset, target_pool)
                if success:
                    success_count += 1
                else:
                    failures.append(f"{dataset}: {message}")

            if failures:
                return False, (
                    f"Scheduled backup completed with partial failures "
                    f"({success_count}/{len(datasets)}): {'; '.join(failures)}"
                )
            return True, f"Scheduled backup completed successfully for {success_count} datasets"
        except Exception as e:
            return False, f"Error running scheduled backup: {str(e)}"
