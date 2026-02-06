#!/usr/bin/env python3
# ZFS Assistant - Core ZFS Operations
# Author: GitHub Copilot

import subprocess
import datetime
from typing import List, Optional, Tuple
import os

# Handle imports for both relative and direct execution
try:
    from ..utils.models import ZFSSnapshot
    from ..utils.logger import (
        OperationType, LogLevel, get_logger,
        log_info, log_error, log_success, log_warning
    )
    from ..utils.common import get_timestamp
    from ..utils.common import (
        is_safe_zfs_token, is_safe_snapshot_prefix,
        is_safe_arc_parameter, is_safe_integer
    )
except ImportError:
    import sys
    import os
    current_dir = os.path.dirname(os.path.abspath(__file__))
    parent_dir = os.path.dirname(current_dir)
    if parent_dir not in sys.path:
        sys.path.insert(0, parent_dir)
    
    from utils.models import ZFSSnapshot
    from utils.logger import (
        OperationType, LogLevel, get_logger,
        log_info, log_error, log_success, log_warning
    )
    from utils.common import get_timestamp
    from utils.common import (
        is_safe_zfs_token, is_safe_snapshot_prefix,
        is_safe_arc_parameter, is_safe_integer
    )


class ZFSCore:
    """
    Core ZFS operations: datasets, snapshots, cloning, rollback.
    """
    
    def __init__(self, privilege_manager, config):
        self.logger = get_logger()
        self.privilege_manager = privilege_manager
        self.config = config

    def update_config(self, config: dict):
        """Update configuration reference when settings are saved"""
        self.config = config
    
    def get_datasets(self) -> List[str]:
        """
        Get list of ZFS datasets.
        
        Returns:
            List of dataset names
        """
        try:
            log_info("Retrieving ZFS datasets")
            
            result = subprocess.run(
                ['zfs', 'list', '-H', '-o', 'name', '-t', 'filesystem'],
                capture_output=True, text=True, check=True
            )
            
            datasets = [line.strip() for line in result.stdout.strip().split('\n') 
                       if line.strip()]
            
            log_success(f"Found {len(datasets)} ZFS datasets")
            return datasets
            
        except subprocess.CalledProcessError as e:
            error_msg = f"Failed to get ZFS datasets: {e.stderr}"
            log_error(error_msg)
            return []
        except Exception as e:
            error_msg = f"Error getting ZFS datasets: {str(e)}"
            log_error(error_msg)
            return []

    def get_zfs_pools(self) -> List[str]:
        """
        Get list of ZFS pool names.
        
        Returns:
            List of pool names
        """
        try:
            log_info("Retrieving ZFS pools")
            
            result = subprocess.run(
                ['zpool', 'list', '-H', '-o', 'name'],
                capture_output=True, text=True, check=True
            )
            
            pools = [line.strip() for line in result.stdout.strip().split('\n') 
                    if line.strip()]
            
            log_success(f"Found {len(pools)} ZFS pools")
            return pools
            
        except subprocess.CalledProcessError as e:
            error_msg = f"Failed to get ZFS pools: {e.stderr}"
            log_error(error_msg)
            return []
        except Exception as e:
            error_msg = f"Error getting ZFS pools: {str(e)}"
            log_error(error_msg)
            return []

    def get_root_pool_datasets(self) -> List[str]:
        """
        Get list of root pool datasets that should be filtered out from user selection.
        
        A root pool dataset is a dataset that matches the pool name exactly (e.g., "zroot").
        These are typically not useful for user operations as they represent the pool root.
        
        Returns:
            List of root pool dataset names to filter out
        """
        try:
            pools = self.get_zfs_pools()
            datasets = self.get_datasets()
            
            # Root pool datasets are those that match pool names exactly
            root_datasets = []
            for pool in pools:
                if pool in datasets:
                    root_datasets.append(pool)
            
            log_info(f"Identified {len(root_datasets)} root pool datasets to filter: {root_datasets}")
            return root_datasets
            
        except Exception as e:
            error_msg = f"Error identifying root pool datasets: {str(e)}"
            log_error(error_msg)
            return []

    def get_filtered_datasets(self) -> List[str]:
        """
        Get list of ZFS datasets filtered to exclude root pool datasets.
        
        Returns:
            List of dataset names suitable for user operations
        """
        try:
            all_datasets = self.get_datasets()
            root_datasets = self.get_root_pool_datasets()
            
            # Filter out root pool datasets
            filtered_datasets = [dataset for dataset in all_datasets 
                               if dataset not in root_datasets]
            
            log_info(f"Filtered {len(all_datasets)} datasets to {len(filtered_datasets)} user-selectable datasets")
            return filtered_datasets
            
        except Exception as e:
            error_msg = f"Error filtering datasets: {str(e)}"
            log_error(error_msg)
            return []
    
    def get_dataset_properties(self, dataset_name: str) -> dict:
        """
        Get properties for a specific ZFS dataset.
        
        Args:
            dataset_name: Name of the dataset
            
        Returns:
            Dictionary of dataset properties
        """
        try:
            log_info(f"Getting properties for dataset: {dataset_name}")
            
            result = subprocess.run(
                ['zfs', 'get', '-H', 'all', dataset_name],
                capture_output=True, text=True, check=True
            )
            
            properties = {}
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    parts = line.split('\t')
                    if len(parts) >= 3:
                        prop_name = parts[1]
                        prop_value = parts[2]
                        properties[prop_name] = prop_value
            
            log_success(f"Retrieved {len(properties)} properties for {dataset_name}")
            return properties
            
        except subprocess.CalledProcessError as e:
            error_msg = f"Failed to get properties for {dataset_name}: {e.stderr}"
            log_error(error_msg)
            return {}
        except Exception as e:
            error_msg = f"Error getting dataset properties: {str(e)}"
            log_error(error_msg)
            return {}
    
    def get_snapshots(self, dataset: Optional[str] = None) -> List[ZFSSnapshot]:
        """
        Get ZFS snapshots, optionally filtered by dataset.
        
        Args:
            dataset: Optional dataset name to filter snapshots
            
        Returns:
            List of ZFSSnapshot objects
        """
        try:
            cmd = ['zfs', 'list', '-H', '-t', 'snapshot', '-o', 'name,creation,used,referenced']
            if dataset:
                cmd.append(dataset)
                log_info(f"Getting snapshots for dataset: {dataset}")
            else:
                log_info("Getting all ZFS snapshots")
            
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            
            snapshots = []
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    parts = line.split('\t')
                    if len(parts) >= 4:
                        full_name = parts[0]
                        if '@' in full_name:
                            dataset_name, snapshot_name = full_name.split('@', 1)
                            
                            # Parse creation time - ZFS returns human-readable format
                            creation_str = parts[1]
                            try:
                                # Try parsing various ZFS date formats
                                # Common format: "Wed Jun 04 10:30 2025"
                                creation_date = datetime.datetime.strptime(creation_str, "%a %b %d %H:%M %Y")
                            except ValueError:
                                try:
                                    # Alternative format with seconds: "Wed Jun 04 10:30:45 2025"
                                    creation_date = datetime.datetime.strptime(creation_str, "%a %b %d %H:%M:%S %Y")
                                except ValueError:
                                    # Keep as string if parsing fails
                                    creation_date = creation_str
                            
                            snapshot = ZFSSnapshot(
                                name=snapshot_name,
                                creation_date=creation_date,
                                dataset=dataset_name,
                                used=parts[2],
                                referenced=parts[3]
                            )
                            snapshots.append(snapshot)
            
            log_success(f"Found {len(snapshots)} snapshots" + 
                       (f" for {dataset}" if dataset else ""))
            return snapshots
            
        except subprocess.CalledProcessError as e:
            error_msg = f"Failed to get snapshots: {e.stderr}"
            log_error(error_msg)
            return []
        except Exception as e:
            error_msg = f"Error getting snapshots: {str(e)}"
            log_error(error_msg)
            return []
    
    def create_snapshot(self, dataset: str, name: Optional[str] = None) -> Tuple[bool, str]:
        """
        Create a ZFS snapshot for the specified dataset.
        
        Args:
            dataset: Dataset name
            name: Optional snapshot name (auto-generated if not provided)
            
        Returns:
            (success, message) tuple
        """
        try:
            if not is_safe_zfs_token(dataset):
                return False, "Invalid dataset name"

            if not name:
                name = f"zfs-assistant-{get_timestamp()}"
            elif not is_safe_zfs_token(name):
                return False, "Invalid snapshot name"
            
            snapshot_full_name = f"{dataset}@{name}"
            
            log_info(f"Creating snapshot: {snapshot_full_name}", {
                'dataset': dataset,
                'snapshot_name': name,
                'operation': 'create'
            })
            
            # Start operation tracking
            operation_id = self.logger.start_operation(OperationType.SCHEDULED_SNAPSHOT, {
                'dataset': dataset,
                'snapshot_name': name,
                'snapshot_full_name': snapshot_full_name
            })
            
            success, result = self.privilege_manager.run_privileged_command([
                'zfs', 'snapshot', snapshot_full_name
            ])
            
            if not success:
                log_error(f"Failed to create snapshot: {snapshot_full_name}", {
                    'error': result,
                    'dataset': dataset,
                    'snapshot_name': name
                })
                self.logger.end_operation(operation_id, False, {'error': result})
                return False, result
            
            log_success(f"Successfully created snapshot: {snapshot_full_name}", {
                'dataset': dataset,
                'snapshot_name': name
            })
            self.logger.log_snapshot_operation('create', dataset, name, True)
            self.logger.end_operation(operation_id, True, {'snapshot_name': snapshot_full_name})
            
            return True, f"Created snapshot {snapshot_full_name}"
            
        except Exception as e:
            error_msg = f"Error creating snapshot: {str(e)}"
            log_error(error_msg, {
                'dataset': dataset,
                'snapshot_name': name,
                'exception': str(e)
            })
            if 'operation_id' in locals():
                self.logger.end_operation(operation_id, False, {'error': error_msg})
            return False, error_msg
    
    def delete_snapshot(self, snapshot_full_name: str) -> Tuple[bool, str]:
        """
        Delete a ZFS snapshot by its full name (dataset@snapshot).
        
        Args:
            snapshot_full_name: Full snapshot name (dataset@snapshot)
            
        Returns:
            (success, message) tuple
        """
        try:
            if not is_safe_zfs_token(snapshot_full_name) or '@' not in snapshot_full_name:
                return False, "Invalid snapshot identifier"

            dataset, snapshot_name = snapshot_full_name.split('@', 1)
            
            log_info(f"Deleting snapshot: {snapshot_full_name}", {
                'dataset': dataset,
                'snapshot_name': snapshot_name,
                'operation': 'delete'
            })
            
            # Start operation tracking
            operation_id = self.logger.start_operation(OperationType.SCHEDULED_SNAPSHOT, {
                'dataset': dataset,
                'snapshot_name': snapshot_name,
                'snapshot_full_name': snapshot_full_name
            })
            
            success, result = self.privilege_manager.run_privileged_command([
                'zfs', 'destroy', snapshot_full_name
            ])
            
            if not success:
                log_error(f"Failed to delete snapshot: {snapshot_full_name}", {
                    'error': result,
                    'dataset': dataset,
                    'snapshot_name': snapshot_name
                })
                self.logger.end_operation(operation_id, False, {'error': result})
                return False, result
            
            log_success(f"Successfully deleted snapshot: {snapshot_full_name}", {
                'dataset': dataset,
                'snapshot_name': snapshot_name
            })
            self.logger.log_snapshot_operation('delete', dataset, snapshot_name, True)
            self.logger.end_operation(operation_id, True, {'snapshot_name': snapshot_full_name})
            
            return True, f"Deleted snapshot {snapshot_full_name}"
            
        except Exception as e:
            error_msg = f"Error deleting snapshot: {str(e)}"
            log_error(error_msg, {
                'snapshot_full_name': snapshot_full_name,
                'exception': str(e)
            })
            if 'operation_id' in locals():
                self.logger.end_operation(operation_id, False, {'error': error_msg})
            return False, error_msg
    
    def rollback_snapshot(self, snapshot_full_name: str, force: bool = False) -> Tuple[bool, str]:
        """
        Rollback to a ZFS snapshot.
        
        Args:
            snapshot_full_name: Full snapshot name (dataset@snapshot)
            force: Whether to force the rollback
            
        Returns:
            (success, message) tuple
        """
        try:
            if not is_safe_zfs_token(snapshot_full_name) or '@' not in snapshot_full_name:
                return False, "Invalid snapshot identifier"

            dataset, snapshot_name = snapshot_full_name.split('@', 1)
            
            log_info(f"Rolling back to snapshot: {snapshot_full_name}", {
                'dataset': dataset,
                'snapshot_name': snapshot_name,
                'force': force,
                'operation': 'rollback'
            })
            
            # Start operation tracking
            operation_id = self.logger.start_operation(OperationType.SCHEDULED_SNAPSHOT, {
                'dataset': dataset,
                'snapshot_name': snapshot_name,
                'snapshot_full_name': snapshot_full_name,
                'force': force
            })
            
            cmd = ['zfs', 'rollback']
            if force:
                cmd.append('-r')
            cmd.append(snapshot_full_name)
            
            success, result = self.privilege_manager.run_privileged_command(cmd)
            
            if not success:
                log_error(f"Failed to rollback to snapshot: {snapshot_full_name}", {
                    'error': result,
                    'dataset': dataset,
                    'snapshot_name': snapshot_name,
                    'force': force
                })
                self.logger.end_operation(operation_id, False, {'error': result})
                return False, result
            
            log_success(f"Successfully rolled back to snapshot: {snapshot_full_name}", {
                'dataset': dataset,
                'snapshot_name': snapshot_name,
                'force': force
            })
            self.logger.log_snapshot_operation('rollback', dataset, snapshot_name, True)
            self.logger.end_operation(operation_id, True, {'snapshot_name': snapshot_full_name})
            
            return True, f"Rolled back to snapshot {snapshot_full_name}"
            
        except Exception as e:
            error_msg = f"Error rolling back snapshot: {str(e)}"
            log_error(error_msg, {
                'snapshot_full_name': snapshot_full_name,
                'force': force,
                'exception': str(e)
            })
            if 'operation_id' in locals():
                self.logger.end_operation(operation_id, False, {'error': error_msg})
            return False, error_msg
    
    def clone_snapshot(self, snapshot_full_name: str, target_name: str) -> Tuple[bool, str]:
        """
        Clone a ZFS snapshot to a new dataset.
        
        Args:
            snapshot_full_name: Full snapshot name (dataset@snapshot)
            target_name: Name for the new cloned dataset
            
        Returns:
            (success, message) tuple
        """
        try:
            if not is_safe_zfs_token(snapshot_full_name) or '@' not in snapshot_full_name:
                return False, "Invalid snapshot identifier"
            if not is_safe_zfs_token(target_name):
                return False, "Invalid target dataset name"

            dataset, snapshot_name = snapshot_full_name.split('@', 1)
            
            log_info(f"Cloning snapshot: {snapshot_full_name} to {target_name}", {
                'source_dataset': dataset,
                'snapshot_name': snapshot_name,
                'source_full_name': snapshot_full_name,
                'target_name': target_name,
                'operation': 'clone'
            })
            
            # Start operation tracking
            operation_id = self.logger.start_operation(OperationType.SCHEDULED_SNAPSHOT, {
                'source_dataset': dataset,
                'snapshot_name': snapshot_name,
                'snapshot_full_name': snapshot_full_name,
                'target_name': target_name
            })
            
            success, result = self.privilege_manager.run_privileged_command([
                'zfs', 'clone', snapshot_full_name, target_name
            ])
            
            if not success:
                log_error(f"Failed to clone snapshot: {snapshot_full_name} to {target_name}", {
                    'error': result,
                    'source_dataset': dataset,
                    'snapshot_name': snapshot_name,
                    'target_name': target_name
                })
                self.logger.end_operation(operation_id, False, {'error': result})
                return False, result
            
            log_success(f"Successfully cloned snapshot: {snapshot_full_name} to {target_name}", {
                'source_dataset': dataset,
                'snapshot_name': snapshot_name,
                'target_name': target_name
            })
            self.logger.log_snapshot_operation('clone', dataset, snapshot_name, True, {
                'target_name': target_name
            })
            self.logger.end_operation(operation_id, True, {
                'snapshot_name': snapshot_full_name,
                'target_name': target_name
            })
            
            return True, f"Cloned snapshot {snapshot_full_name} to {target_name}"
            
        except Exception as e:
            error_msg = f"Error cloning snapshot: {str(e)}"
            log_error(error_msg, {
                'snapshot_full_name': snapshot_full_name,
                'target_name': target_name,
                'exception': str(e)
            })
            if 'operation_id' in locals():
                self.logger.end_operation(operation_id, False, {'error': error_msg})
            return False, error_msg
    
    def cleanup_snapshots(self, dataset: str, retention_policy: dict) -> Tuple[bool, str]:
        """
        Clean up old snapshots based on retention policy.
        
        Args:
            dataset: Dataset to clean up
            retention_policy: Dictionary with retention rules
            
        Returns:
            (success, message) tuple
        """
        try:
            log_info(f"Starting snapshot cleanup for dataset: {dataset}", {
                'dataset': dataset,
                'retention_policy': retention_policy
            })
            
            # Get all snapshots for the dataset
            snapshots = self.get_snapshots(dataset)
            if not snapshots:
                return True, f"No snapshots found for dataset {dataset}"
            
            # Sort snapshots by creation date (newest first)
            sorted_snapshots = sorted(
                snapshots,
                key=lambda x: x.creation_date if isinstance(x.creation_date, datetime.datetime) 
                         else datetime.datetime.min,
                reverse=True
            )
            
            snapshots_to_delete = []
            
            # Apply retention policy
            keep_count = retention_policy.get('keep_count', 10)
            max_age_days = retention_policy.get('max_age_days', 30)
            
            for i, snapshot in enumerate(sorted_snapshots):
                should_delete = False
                
                # Check count-based retention
                if i >= keep_count:
                    should_delete = True
                
                # Check age-based retention
                if isinstance(snapshot.creation_date, datetime.datetime):
                    age_days = (datetime.datetime.now() - snapshot.creation_date).days
                    if age_days > max_age_days:
                        should_delete = True
                
                if should_delete:
                    snapshots_to_delete.append(snapshot)
            
            if not snapshots_to_delete:
                return True, f"No snapshots to clean up for dataset {dataset}"
            
            # Prepare batch deletion commands to reduce pkexec prompts
            delete_commands = []
            for snapshot in snapshots_to_delete:
                delete_commands.append(['zfs', 'destroy', snapshot.full_name])
            
            log_info(f"Deleting {len(snapshots_to_delete)} old snapshots in batch for dataset {dataset}")
            
            # Execute batch deletion
            success, batch_result = self.privilege_manager.run_batch_privileged_commands(delete_commands)
            
            if success:
                deleted_count = len(snapshots_to_delete)
                failed_count = 0
                
                # Log each successful deletion for tracking
                for snapshot in snapshots_to_delete:
                    self.logger.log_snapshot_operation('delete', dataset, snapshot.name, True)
                    
                message = f"Cleanup completed for {dataset}: {deleted_count} snapshots deleted successfully"
                log_success(message)
                return True, message
            else:
                # If batch fails, log all as failed
                for snapshot in snapshots_to_delete:
                    self.logger.log_snapshot_operation('delete', dataset, snapshot.name, False, 
                                                     {'error': batch_result})
                
                message = f"Cleanup failed for {dataset}: batch deletion failed - {batch_result}"
                log_error(message)
                return False, message
            
        except Exception as e:
            error_msg = f"Error during snapshot cleanup: {str(e)}"
            log_error(error_msg, {
                'dataset': dataset,
                'retention_policy': retention_policy,
                'exception': str(e)
            })
            return False, error_msg
    
    def create_batch_snapshots(self, datasets: List[str], snapshot_name: str) -> Tuple[bool, str]:
        """
        Create snapshots for multiple datasets in a single batch operation.
        This reduces pkexec prompts by batching all snapshot commands together.
        
        Args:
            datasets: List of dataset names to snapshot
            snapshot_name: Name for the snapshots (will be applied to all datasets)
            
        Returns:
            (success, message) tuple with batch operation results
        """
        try:
            if not datasets:
                return False, "No datasets provided for batch snapshot creation"
                
            log_info(f"Creating batch snapshots for {len(datasets)} datasets", {
                'datasets': datasets,
                'snapshot_name': snapshot_name,
                'operation': 'batch_create'
            })
            
            # Start operation tracking
            operation_id = self.logger.start_operation(OperationType.SCHEDULED_SNAPSHOT, {
                'datasets': datasets,
                'snapshot_name': snapshot_name,
                'batch_operation': True,
                'dataset_count': len(datasets)
            })
            
            # Build batch commands
            snapshot_commands = []
            snapshot_details = []
            
            for dataset in datasets:
                snapshot_full_name = f"{dataset}@{snapshot_name}"
                snapshot_commands.append(['zfs', 'snapshot', snapshot_full_name])
                snapshot_details.append({
                    'dataset': dataset,
                    'snapshot_name': snapshot_name,
                    'snapshot_full_name': snapshot_full_name
                })
            
            # Execute batch operation
            success, batch_result = self.privilege_manager.run_batch_privileged_commands(snapshot_commands)
            
            if success:
                # Log each successful snapshot creation for tracking
                for detail in snapshot_details:
                    self.logger.log_snapshot_operation('create', detail['dataset'], 
                                                     detail['snapshot_name'], True)
                    log_success(f"Created snapshot: {detail['snapshot_full_name']}")
                
                success_msg = f"Successfully created {len(datasets)} snapshots in batch"
                log_success(success_msg)
                self.logger.end_operation(operation_id, True, {
                    'snapshots_created': len(datasets),
                    'snapshot_details': snapshot_details
                })
                return True, success_msg
            else:
                # Log all as failed since it was a batch operation
                for detail in snapshot_details:
                    self.logger.log_snapshot_operation('create', detail['dataset'], 
                                                     detail['snapshot_name'], False, 
                                                     {'error': batch_result})
                    log_error(f"Failed to create snapshot: {detail['snapshot_full_name']}")
                
                error_msg = f"Batch snapshot creation failed: {batch_result}"
                log_error(error_msg)
                self.logger.end_operation(operation_id, False, {'error': error_msg})
                return False, error_msg
                
        except Exception as e:
            error_msg = f"Error during batch snapshot creation: {str(e)}"
            log_error(error_msg, {
                'datasets': datasets,
                'snapshot_name': snapshot_name,
                'exception': str(e)
            })
            if 'operation_id' in locals():
                self.logger.end_operation(operation_id, False, {'error': error_msg})
            return False, error_msg
    
    def create_scheduled_snapshot(self, interval: str) -> Tuple[bool, str]:
        """
        Create scheduled snapshots for all configured datasets with streamlined logging.
        This method is called by systemd timers and properly uses the streamlined logging system.
        
        Args:
            interval: Type of scheduled snapshot (daily, weekly, monthly)
            
        Returns:
            (success, message) tuple
        """
        try:
            # Start scheduled operation with proper logging
            if interval == "daily":
                description = "Daily Snapshot Creation"
            elif interval == "weekly":
                description = "Weekly Snapshot Creation"
            elif interval == "monthly":
                description = "Monthly Snapshot Creation"
            else:
                description = f"{interval.capitalize()} Snapshot Creation"
            
            self.logger.start_scheduled_operation(OperationType.SCHEDULED_SNAPSHOT, description)
            
            # Get configured datasets
            datasets = self.config.get("datasets", [])
            if not datasets:
                self.logger.log_essential_message(LogLevel.INFO, "No datasets configured for snapshots")
                self.logger.end_scheduled_operation(True, "No datasets to snapshot")
                return True, "No datasets configured"
            
            # Generate snapshot name
            timestamp = get_timestamp()
            prefix = self.config.get("prefix", "zfs-assistant")
            if not is_safe_snapshot_prefix(prefix):
                error_msg = f"Invalid snapshot prefix in config: {prefix}"
                self.logger.log_essential_message(LogLevel.ERROR, error_msg)
                self.logger.end_scheduled_operation(False, error_msg)
                return False, error_msg
            snapshot_name = f"{prefix}-{interval}-{timestamp}"
            
            # Log essential details
            self.logger.log_essential_message(LogLevel.INFO, f"Creating {interval} snapshots for {len(datasets)} datasets")
            
            # Create batch snapshots
            batch_commands = []
            for dataset in datasets:
                if not is_safe_zfs_token(dataset):
                    error_msg = f"Invalid dataset in config: {dataset}"
                    self.logger.log_essential_message(LogLevel.ERROR, error_msg)
                    self.logger.end_scheduled_operation(False, error_msg)
                    return False, error_msg
                snapshot_full_name = f"{dataset}@{snapshot_name}"
                batch_commands.append(['zfs', 'snapshot', snapshot_full_name])
            
            # Execute batch operation with elevated privileges
            success, batch_result = self.privilege_manager.run_batch_privileged_commands(batch_commands)
            
            if success:
                # Log individual successful snapshots
                for dataset in datasets:
                    snapshot_full_name = f"{dataset}@{snapshot_name}"
                    self.logger.log_snapshot_operation('create', dataset, snapshot_name, True)
                    self.logger.log_essential_message(LogLevel.SUCCESS, f"Created snapshot: {snapshot_full_name}")
                
                success_msg = f"Successfully created {len(datasets)} {interval} snapshots"
                self.logger.log_essential_message(LogLevel.SUCCESS, success_msg)
                self.logger.end_scheduled_operation(True, f"Created {len(datasets)} snapshots successfully")
                return True, success_msg
            else:
                # Log all as failed since it was a batch operation
                for dataset in datasets:
                    snapshot_full_name = f"{dataset}@{snapshot_name}"
                    self.logger.log_snapshot_operation('create', dataset, snapshot_name, False, {'error': batch_result})
                    self.logger.log_essential_message(LogLevel.ERROR, f"Failed to create snapshot: {snapshot_full_name}")
                
                error_msg = f"Batch {interval} snapshot creation failed: {batch_result}"
                self.logger.log_essential_message(LogLevel.ERROR, error_msg)
                self.logger.end_scheduled_operation(False, error_msg)
                return False, error_msg
                
        except Exception as e:
            error_msg = f"Error during {interval} scheduled snapshot creation: {str(e)}"
            self.logger.log_essential_message(LogLevel.ERROR, error_msg)
            self.logger.end_scheduled_operation(False, error_msg)
            return False, error_msg
    
    def get_arc_properties(self) -> dict:
        """
        Get ZFS ARC (Adaptive Replacement Cache) statistics and properties.
        
        Returns:
            Dictionary of ARC properties organized by category
        """
        try:
            log_info("Getting ARC properties")
            
            # Read ARC statistics from /proc/spl/kstat/zfs/arcstats
            arcstats_path = "/proc/spl/kstat/zfs/arcstats"
            if not os.path.exists(arcstats_path):
                log_warning("ARC statistics not available - ZFS may not be loaded")
                return {}
            
            arc_properties = {}
            
            with open(arcstats_path, 'r') as f:
                lines = f.readlines()
            
            # Skip header lines
            for line in lines[2:]:  # Skip the first two header lines
                line = line.strip()
                if not line:
                    continue
                    
                parts = line.split()
                if len(parts) >= 3:
                    name = parts[0]
                    value = parts[2]
                    arc_properties[name] = value
            
            # Organize properties into categories
            categorized_properties = {
                "Cache Statistics": {
                    "Total Hits": arc_properties.get("hits", "0"),
                    "Total Misses": arc_properties.get("misses", "0"),
                    "Hit Rate": self._calculate_hit_rate(arc_properties),
                    "Demand Data Hits": arc_properties.get("demand_data_hits", "0"),
                    "Demand Data Misses": arc_properties.get("demand_data_misses", "0"),
                    "Demand Metadata Hits": arc_properties.get("demand_metadata_hits", "0"),
                    "Demand Metadata Misses": arc_properties.get("demand_metadata_misses", "0"),
                },
                "Memory Usage": {
                    "ARC Size": self._format_bytes(arc_properties.get("size", "0")),
                    "ARC Maximum Size": self._format_bytes(arc_properties.get("c_max", "0")),
                    "ARC Target Size": self._format_bytes(arc_properties.get("c", "0")),
                    "ARC Minimum Size": self._format_bytes(arc_properties.get("c_min", "0")),
                    "MRU Size": self._format_bytes(arc_properties.get("p", "0")),
                    "Data Size": self._format_bytes(arc_properties.get("data_size", "0")),
                    "Metadata Size": self._format_bytes(arc_properties.get("meta_size", "0")),
                },
                "Cache Lists": {
                    "MRU Hits": arc_properties.get("mru_hits", "0"),
                    "MRU Ghost Hits": arc_properties.get("mru_ghost_hits", "0"),
                    "MFU Hits": arc_properties.get("mfu_hits", "0"),
                    "MFU Ghost Hits": arc_properties.get("mfu_ghost_hits", "0"),
                    "Prefetch Data Hits": arc_properties.get("prefetch_data_hits", "0"),
                    "Prefetch Metadata Hits": arc_properties.get("prefetch_metadata_hits", "0"),
                },
                "Efficiency": {
                    "Read Hits": arc_properties.get("iohits", "0"),
                    "Sync Wait for Read": arc_properties.get("sync_wait_for_async", "0"),
                    "Async Upgrade Sync": arc_properties.get("async_upgrade_sync", "0"),
                    "Evict Skip": arc_properties.get("evict_skip", "0"),
                    "Mutex Miss": arc_properties.get("mutex_miss", "0"),
                }
            }
            
            log_success(f"Retrieved ARC properties with {len(arc_properties)} statistics")
            return categorized_properties
            
        except Exception as e:
            error_msg = f"Error getting ARC properties: {str(e)}"
            log_error(error_msg)
            return {}
    
    def _calculate_hit_rate(self, arc_properties: dict) -> str:
        """Calculate ARC hit rate percentage."""
        try:
            hits = int(arc_properties.get("hits", "0"))
            misses = int(arc_properties.get("misses", "0"))
            total = hits + misses
            
            if total == 0:
                return "0.00%"
            
            hit_rate = (hits / total) * 100
            return f"{hit_rate:.2f}%"
        except (ValueError, ZeroDivisionError):
            return "N/A"
    
    def _format_bytes(self, byte_str: str) -> str:
        """Format bytes into human-readable format."""
        try:
            bytes_val = int(byte_str)
            if bytes_val == 0:
                return "0 B"
            
            units = ['B', 'KB', 'MB', 'GB', 'TB']
            unit_index = 0
            
            while bytes_val >= 1024 and unit_index < len(units) - 1:
                bytes_val /= 1024
                unit_index += 1
            
            return f"{bytes_val:.1f} {units[unit_index]}"
        except ValueError:
            return byte_str
    
    def get_arc_tunables(self) -> dict:
        """
        Get ZFS ARC tunable parameters that can be modified.
        
        Returns:
            Dictionary of tunable ARC parameters
        """
        try:
            log_info("Getting ARC tunable parameters")
            
            tunables = {}
            
            # Common ARC tunables from /sys/module/zfs/parameters/
            tunable_params = {
                "zfs_arc_max": "Maximum ARC size (bytes)",
                "zfs_arc_min": "Minimum ARC size (bytes)", 
                "zfs_arc_meta_limit": "ARC metadata limit (bytes)",
                "zfs_arc_meta_min": "ARC metadata minimum (bytes)",
                "zfs_arc_shrink_shift": "ARC shrink shift",
                "zfs_arc_grow_retry": "ARC grow retry interval",
                "zfs_arc_p_min_shift": "ARC target size minimum shift"
            }
            
            for param, description in tunable_params.items():
                param_path = f"/sys/module/zfs/parameters/{param}"
                if os.path.exists(param_path):
                    try:
                        with open(param_path, 'r') as f:
                            value = f.read().strip()
                        tunables[param] = {
                            "value": value,
                            "description": description,
                            "editable": True
                        }
                    except Exception:
                        tunables[param] = {
                            "value": "N/A",
                            "description": description, 
                            "editable": False
                        }
            
            log_success(f"Retrieved {len(tunables)} ARC tunable parameters")
            return tunables
            
        except Exception as e:
            error_msg = f"Error getting ARC tunables: {str(e)}"
            log_error(error_msg)
            return {}
    
    def set_arc_tunable(self, parameter: str, value: str) -> Tuple[bool, str]:
        """
        Set an ARC tunable parameter.
        
        Args:
            parameter: Name of the tunable parameter
            value: New value to set
            
        Returns:
            (success, message) tuple
        """
        try:
            log_info(f"Setting ARC tunable: {parameter} = {value}")
            if not is_safe_arc_parameter(parameter):
                return False, "Invalid ARC parameter name"
            if not is_safe_integer(value):
                return False, "Invalid ARC parameter value (integer expected)"
            
            param_path = f"/sys/module/zfs/parameters/{parameter}"
            if not os.path.exists(param_path):
                return False, f"Parameter {parameter} not found"
            
            # Use tee (without shell) to write the new value.
            success, result = self.privilege_manager.run_privileged_command([
                'tee', param_path
            ], input_text=f"{value.strip()}\n")
            
            if not success:
                log_error(f"Failed to set ARC tunable {parameter}: {result}")
                return False, f"Failed to set {parameter}: {result}"
            
            log_success(f"Successfully set ARC tunable: {parameter} = {value}")
            return True, f"Set {parameter} to {value}"
            
        except Exception as e:
            error_msg = f"Error setting ARC tunable: {str(e)}"
            log_error(error_msg)
            return False, error_msg
