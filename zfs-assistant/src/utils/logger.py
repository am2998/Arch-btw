#!/usr/bin/env python3
"""
ZFS Assistant - Streamlined Logging System
Focused logging for essential scheduled operations only: snapshot creation, system updates, flatpak updates, cache cleaning
Maintains only the last 5 scheduled operations with clear start/end headers
"""

import os
import re
import datetime
import logging
from pathlib import Path
from typing import Optional, Dict, Any, List
from enum import Enum

# Import LOG_FILE constant from common
try:
    from .common import LOG_FILE
except ImportError:
    try:
        from common import LOG_FILE
    except ImportError:
        # Fallback if import fails
        LOG_FILE = "/var/log/zfs-assistant.log"

class OperationType(Enum):
    """Essential operation types for scheduled logging"""
    SCHEDULED_SNAPSHOT = "scheduled_snapshot"
    SYSTEM_UPDATE = "system_update"
    FLATPAK_UPDATE = "flatpak_update" 
    CACHE_CLEANUP = "cache_cleanup"
    SYSTEM_MAINTENANCE = "system_maintenance"  # Combined operations

class LogLevel(Enum):
    """Log levels for scheduled operations"""
    INFO = "INFO"
    ERROR = "ERROR"
    SUCCESS = "SUCCESS"

class ZFSLogger:
    """
    Streamlined logging system for ZFS Assistant scheduled operations
    Focuses only on essential operations with clean start/end headers
    Maintains only the last 5 scheduled operations
    """
    def __init__(self, log_file: str = None):
        """
        Initialize the streamlined logger
        
        Args:
            log_file: Path to the log file (defaults to LOG_FILE constant)
        """
        if log_file is None:
            log_file = LOG_FILE
        self.log_file = Path(log_file)
        
        # Ensure the log directory exists
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        
        # Create log file if it doesn't exist
        if not self.log_file.exists():
            try:
                self.log_file.touch()
            except Exception as e:
                print(f"Warning: Could not create log file {self.log_file}: {e}")
        
        # Current operation context
        self.current_operation: Optional[Dict[str, Any]] = None
        
        # Setup standard Python logging for backward compatibility
        self._setup_python_logging()
    
    def _setup_python_logging(self):
        """Setup standard Python logging for integration with existing code"""
        self.python_logger = logging.getLogger('zfs_assistant')
        self.python_logger.setLevel(logging.INFO)  # Only INFO and above for essential operations
        
        # Create formatter
        formatter = logging.Formatter(
            '[%(asctime)s] - %(levelname)s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        
        # File handler for main log
        if not self.python_logger.handlers:
            try:
                file_handler = logging.FileHandler(self.log_file)
            except Exception:
                fallback_log = Path("/tmp/zfs-assistant.log")
                self.log_file = fallback_log
                file_handler = logging.FileHandler(self.log_file)
            file_handler.setLevel(logging.INFO)
            file_handler.setFormatter(formatter)
            self.python_logger.addHandler(file_handler)
    
    def _get_timestamp(self) -> str:
        """Get current timestamp in readable format"""
        return datetime.datetime.now().strftime('%a %d %b %Y, %H:%M:%S')
    
    def _write_to_log(self, content: str):
        """Write content to log file"""
        try:
            # Ensure log file exists before writing
            if not self.log_file.exists():
                self.log_file.parent.mkdir(parents=True, exist_ok=True)
                self.log_file.touch()
            
            with open(self.log_file, 'a', encoding='utf-8') as f:
                f.write(content + '\n')
        except Exception as e:
            # Fallback to stderr if log file fails
            print(f"LOG_ERROR: Failed to write to {self.log_file}: {e}")
            print(content)
    
    def start_scheduled_operation(self, operation_type: OperationType, description: str):
        """
        Start logging a scheduled operation with clear header
        
        Args:
            operation_type: Type of scheduled operation
            description: Human-readable description of the operation
        """
        start_time = datetime.datetime.now()
        timestamp = self._get_timestamp()
        
        self.current_operation = {
            'type': operation_type,
            'description': description,
            'start_time': start_time,
            'operation_id': f"{operation_type.value}_{start_time.strftime('%Y%m%d_%H%M')}"
        }
        
        # Create clear start header
        header_line = "=" * 80
        start_header = f"""
{header_line}
=== SCHEDULED OPERATION START | {timestamp} ===
=== {description.upper()} ===
{header_line}
"""
        
        self._write_to_log(start_header)
        self.python_logger.info(f"Started scheduled operation: {description}")
    
    def log_essential_message(self, level: LogLevel, message: str):
        """
        Log an essential message for scheduled operations
        
        Args:
            level: Log level 
            message: Message to log
        """
        timestamp = self._get_timestamp()
        log_entry = f"[{timestamp}] - {level.value} - {message}"
        
        self._write_to_log(log_entry)
        
        # Log to Python logger at appropriate level
        python_level = getattr(logging, level.value, logging.INFO)
        self.python_logger.log(python_level, message)
    
    def end_scheduled_operation(self, success: bool, summary: Optional[str] = None):
        """
        End the current scheduled operation with clear footer
        
        Args:
            success: Whether the operation was successful
            summary: Optional summary message
        """
        if not self.current_operation:
            self.log_essential_message(LogLevel.ERROR, "Attempted to end operation but no operation was started")
            return
        
        end_time = datetime.datetime.now()
        duration = end_time - self.current_operation['start_time']
        timestamp = self._get_timestamp()
        
        operation_desc = self.current_operation['description']
        
        # Determine result status
        if success:
            result_status = "COMPLETED SUCCESSFULLY"
            level = LogLevel.SUCCESS
        else:
            result_status = "FAILED"
            level = LogLevel.ERROR
        
        # Create clear end header
        header_line = "=" * 80
        end_header = f"""
[{timestamp}] - {level.value} - Operation {result_status}: {operation_desc}
Duration: {duration}
{summary if summary else ''}
{header_line}
=== SCHEDULED OPERATION END | {timestamp} ===
{header_line}

"""
        
        self._write_to_log(end_header)
        
        # Log to Python logger
        python_level = logging.INFO if success else logging.ERROR
        self.python_logger.log(python_level, f"Ended scheduled operation: {operation_desc} - {result_status} (Duration: {duration})")
        
        # Clear current operation
        self.current_operation = None
        
        # Clean up old operations after each completed operation
        self.cleanup_old_scheduled_operations()
    
    def cleanup_old_scheduled_operations(self, keep_count: int = 5):
        """
        Keep only the last N scheduled operations in the log file
        
        Args:
            keep_count: Number of most recent scheduled operations to keep
        """
        try:
            if not self.log_file.exists():
                # Create empty log file if it doesn't exist
                self.log_file.parent.mkdir(parents=True, exist_ok=True)
                self.log_file.touch()
                return
                
            with open(self.log_file, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Find all scheduled operation blocks
            operation_pattern = r'=== SCHEDULED OPERATION START.*?=== SCHEDULED OPERATION END.*?={80,}\s*\n*'
            operations = re.findall(operation_pattern, content, re.DOTALL)
            
            if len(operations) <= keep_count:
                return  # No cleanup needed
            
            # Keep only the last N operations
            operations_to_keep = operations[-keep_count:]
            
            # Reconstruct the log file with only recent operations
            new_content = ''.join(operations_to_keep)
            
            with open(self.log_file, 'w', encoding='utf-8') as f:
                f.write(new_content)
            
            self.log_essential_message(LogLevel.INFO, f"Cleaned up log file, keeping last {keep_count} scheduled operations")
            
        except Exception as e:
            self.log_essential_message(LogLevel.ERROR, f"Failed to cleanup old scheduled operations: {e}")

    # Legacy method compatibility for existing code
    def start_operation(self, operation_type, details: dict = None):
        """Legacy compatibility method - converts to scheduled operation if applicable"""
        if hasattr(operation_type, 'value'):
            # Convert old operation types to new essential types where applicable
            old_to_new_mapping = {
                'snapshot_scheduled': OperationType.SCHEDULED_SNAPSHOT,
                'snapshot_create': OperationType.SCHEDULED_SNAPSHOT,
                'system_update': OperationType.SYSTEM_UPDATE,
                'cache_cleanup': OperationType.CACHE_CLEANUP,
                'system_maintenance': OperationType.SYSTEM_UPDATE  # Map maintenance to system update
            }
            
            new_type = old_to_new_mapping.get(operation_type.value)
            if new_type:
                description = details.get('description', f'{operation_type.value} operation') if details else f'{operation_type.value} operation'
                self.start_scheduled_operation(new_type, description)
                return operation_type.value  # Return operation ID for compatibility
        
        # For non-essential operations, just return a dummy ID
        return "non_essential_operation"
    
    def log_message(self, level, message: str, details: dict = None):
        """Legacy compatibility method - only logs essential messages"""
        if hasattr(level, 'value'):
            level_value = level.value
        else:
            level_value = str(level)
            
        # Only log essential messages during scheduled operations
        if self.current_operation and level_value in ['INFO', 'ERROR', 'SUCCESS']:
            new_level = LogLevel(level_value)
            self.log_essential_message(new_level, message)
    
    def end_operation(self, operation_id, success: bool, details: dict = None):
        """Legacy compatibility method"""
        if self.current_operation:
            summary = details.get('summary') if details else None
            self.end_scheduled_operation(success, summary)
    
    # Simplified methods for essential operations only
    def log_snapshot_operation(self, operation: str, dataset: str, snapshot_name: str, success: bool, details: dict = None):
        """Log essential snapshot operations during scheduled operations only"""
        if self.current_operation and self.current_operation['type'] == OperationType.SCHEDULED_SNAPSHOT:
            level = LogLevel.SUCCESS if success else LogLevel.ERROR
            message = f"Snapshot {operation}: {dataset}@{snapshot_name}"
            self.log_essential_message(level, message)
    
    def log_system_command(self, command: List[str], success: bool, output: str = None, error: str = None):
        """Log essential system commands during scheduled operations only"""
        if self.current_operation:
            level = LogLevel.SUCCESS if success else LogLevel.ERROR
            command_str = " ".join(command)
            
            # Only log essential commands
            essential_commands = ['pacman -Syu', 'pacman -Scc', 'flatpak update', 'zfs snapshot']
            if any(essential in command_str for essential in essential_commands):
                message = f"System command: {command_str}"
                if not success and error:
                    message += f" - Error: {error}"
                self.log_essential_message(level, message)

    def log_backup_operation(self, dataset: str, snapshot_name: str, target_pool: str,
                             backup_type: str, success: bool, details: dict = None):
        """Legacy compatibility method for backup operation logging."""
        if self.current_operation:
            level = LogLevel.SUCCESS if success else LogLevel.ERROR
            message = (
                f"Backup {backup_type}: {dataset}@{snapshot_name} -> {target_pool}"
            )
            if not success and details and details.get("error"):
                message += f" - Error: {details['error']}"
            self.log_essential_message(level, message)

# Global logger instance
_logger_instance: Optional[ZFSLogger] = None

def get_logger() -> ZFSLogger:
    """Get the global logger instance"""
    global _logger_instance
    if _logger_instance is None:
        _logger_instance = ZFSLogger()
    return _logger_instance
# Convenience functions for essential operations only
def log_info(message: str, details: Optional[Dict[str, Any]] = None):
    """Convenience function to log info message during scheduled operations"""
    logger = get_logger()
    if logger.current_operation:
        logger.log_essential_message(LogLevel.INFO, message)

def log_error(message: str, details: Optional[Dict[str, Any]] = None):
    """Convenience function to log error message during scheduled operations"""
    logger = get_logger()
    if logger.current_operation:
        logger.log_essential_message(LogLevel.ERROR, message)

def log_success(message: str, details: Optional[Dict[str, Any]] = None):
    """Convenience function to log success message during scheduled operations"""
    logger = get_logger()
    if logger.current_operation:
        logger.log_essential_message(LogLevel.SUCCESS, message)

def log_warning(message: str, details: Optional[Dict[str, Any]] = None):
    """Convenience function - warnings not logged in streamlined version"""
    # Warnings are not considered essential for scheduled operations
    pass
