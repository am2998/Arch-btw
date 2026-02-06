#!/usr/bin/env python3
# ZFS Assistant - Schedule Settings Tab
# Author: GitHub Copilot

import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk
try:
    from ...utils.common import is_safe_snapshot_prefix
except Exception:
    try:
        from utils.common import is_safe_snapshot_prefix
    except Exception:
        def is_safe_snapshot_prefix(value):
            return bool(value and isinstance(value, str))

class ScheduleSettingsTab:
    """Schedule settings tab for snapshot scheduling and retention"""
    
    def __init__(self, parent_dialog):
        self.dialog = parent_dialog
        self.zfs_assistant = parent_dialog.zfs_assistant
        self.config = parent_dialog.config
        
        # Initialize collections for controls
        self.day_checks = {}
        
        # Build the schedule settings UI
        self._build_ui()
        
        # Set initial states
        self._set_initial_schedule_state()
    
    def _build_ui(self):
        """Build the schedule settings tab UI"""
        # Create main container with reduced spacing for compactness
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.box.set_margin_top(8)
        self.box.set_margin_bottom(8)
        self.box.set_margin_start(10)
        self.box.set_margin_end(10)
        
        # Enable scheduled snapshots
        self._create_schedule_enable_section()
        
        # Managed datasets section (moved from General tab)
        self._create_managed_datasets_section()
        
        # Schedule types configuration (create before naming to avoid AttributeError)
        self._create_schedule_types_section()
        
        # Snapshot naming configuration
        self._create_naming_section()
        
        # Retention policy configuration
        self._create_retention_section()
        
        # Update initial snapshot preview after all UI components are created
        self.update_snapshot_preview()
    
    def _create_schedule_enable_section(self):
        """Create the schedule enable/disable section"""
        self.schedule_switch = Gtk.Switch()
        self.schedule_switch.set_active(self.config.get("auto_snapshot", True))
        self.schedule_switch.connect("state-set", self.on_schedule_switch_toggled)
        schedule_enable_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        schedule_enable_box.append(Gtk.Label(label="Enable Scheduled Snapshots:"))
        schedule_enable_box.append(self.schedule_switch)
        self.box.append(schedule_enable_box)
        
        # Add explanation text (shorter)
        explanation_label = Gtk.Label(
            label="Automated snapshots help protect your data by creating regular backups. "
                  "Choose one schedule type below and select datasets to include."
        )
        
        explanation_label.set_wrap(True)
        explanation_label.set_margin_top(4)
        explanation_label.set_margin_bottom(4)
        explanation_label.set_halign(Gtk.Align.START)
        explanation_label.set_margin_start(0)  # Align with frame content
        explanation_label.add_css_class("dim-label")
        self.box.append(explanation_label)
    
    def _create_managed_datasets_section(self):
        """Create the managed datasets selection section"""
        datasets_frame = Gtk.Frame()
        datasets_frame.set_label("Datasets to Include in Scheduled Snapshots")
        datasets_frame.set_margin_top(5)
        datasets_frame.set_margin_bottom(5)
        self.box.append(datasets_frame)
        
        datasets_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        datasets_box.set_margin_top(6)
        datasets_box.set_margin_bottom(6)
        datasets_box.set_margin_start(10)
        datasets_box.set_margin_end(10)
        datasets_frame.set_child(datasets_box)
        
        # Add explanation for dataset selection (shorter text)
        dataset_explanation = Gtk.Label(
            label="Select which ZFS datasets should be included in your scheduled snapshots."
        )
        dataset_explanation.set_wrap(True)
        dataset_explanation.set_margin_bottom(6)
        dataset_explanation.set_halign(Gtk.Align.START)
        dataset_explanation.set_margin_start(0)
        dataset_explanation.add_css_class("dim-label")
        datasets_box.append(dataset_explanation)
        
        # Dataset list with checkboxes - more compact
        datasets_scroll = Gtk.ScrolledWindow()
        datasets_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        datasets_scroll.set_size_request(-1, 100)  # Reduced height for compactness
        datasets_scroll.set_vexpand(False)  # Don't expand vertically
        datasets_box.append(datasets_scroll)
        
        # Create a list box for datasets
        self.datasets_list = Gtk.ListBox()
        self.datasets_list.set_selection_mode(Gtk.SelectionMode.NONE)
        datasets_scroll.set_child(self.datasets_list)
        
        # Get available datasets (exclude root pool datasets)
        datasets = self.zfs_assistant.get_filtered_datasets()
        managed_datasets = self.config.get("datasets", [])
        
        # Add datasets to the list
        if datasets:
            for dataset in datasets:
                dataset_name = dataset
                row = Gtk.ListBoxRow()
                box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
                box.set_margin_top(5)
                box.set_margin_bottom(5)
                box.set_margin_start(5)
                box.set_margin_end(5)
                
                check = Gtk.CheckButton(label=dataset_name)
                check.set_active(dataset_name in managed_datasets)
                box.append(check)
                
                row.set_child(box)
                self.datasets_list.append(row)
        else:
            # Show message when no datasets are available
            no_datasets_label = Gtk.Label(label="No ZFS datasets found to manage")
            no_datasets_label.set_halign(Gtk.Align.CENTER)
            no_datasets_label.add_css_class("dim-label")
            datasets_box.append(no_datasets_label)
        
        # Add buttons for selecting all/none
        if datasets:  # Only show buttons if there are datasets
            button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            button_box.set_margin_top(6)
            
            select_all_button = Gtk.Button(label="Select All Datasets")
            select_all_button.connect("clicked", self.on_select_all_datasets_clicked)
            button_box.append(select_all_button)
            
            select_none_button = Gtk.Button(label="Clear All Datasets")
            select_none_button.connect("clicked", self.on_select_none_datasets_clicked)
            button_box.append(select_none_button)
            
            datasets_box.append(button_box)
    
    def _create_naming_section(self):
        """Create the snapshot naming configuration section"""
        naming_frame = Gtk.Frame()
        naming_frame.set_label("Snapshot Naming")
        naming_frame.set_margin_top(5)
        naming_frame.set_margin_bottom(5)
        self.box.append(naming_frame)
        
        naming_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        naming_box.set_margin_top(6)
        naming_box.set_margin_bottom(6)
        naming_box.set_margin_start(10)
        naming_box.set_margin_end(10)
        naming_frame.set_child(naming_box)
        
        # Create horizontal layout for naming settings
        naming_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=15)
        naming_row.set_halign(Gtk.Align.START)
        naming_box.append(naming_row)
        
        # Prefix setting
        prefix_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        prefix_label = Gtk.Label(label="Prefix:")
        prefix_label.set_size_request(60, -1)
        prefix_label.set_halign(Gtk.Align.START)
        prefix_box.append(prefix_label)
        
        self.prefix_entry = Gtk.Entry()
        self.prefix_entry.set_text(self.config.get("prefix", "zfs-assistant"))
        self.prefix_entry.set_size_request(150, -1)
        prefix_box.append(self.prefix_entry)
        naming_row.append(prefix_box)
        
        # Name format dropdown
        format_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        format_label = Gtk.Label(label="Format:")
        format_label.set_size_request(60, -1)
        format_label.set_halign(Gtk.Align.START)
        format_box.append(format_label)
        
        self.format_combo = Gtk.DropDown()
        format_model = Gtk.StringList.new([
            "prefix-type-timestamp",
            "prefix-timestamp-type", 
            "type-prefix-timestamp",
            "timestamp-prefix-type"
        ])
        self.format_combo.set_model(format_model)
        
        # Set current format
        current_format = self.config.get("snapshot_name_format", "prefix-type-timestamp")
        format_options = [
            "prefix-type-timestamp", "prefix-timestamp-type", "type-prefix-timestamp", "timestamp-prefix-type"
        ]
        try:
            current_index = format_options.index(current_format)
            self.format_combo.set_selected(current_index)
        except ValueError:
            self.format_combo.set_selected(0)
        
        self.format_combo.set_size_request(180, -1)
        format_box.append(self.format_combo)
        naming_row.append(format_box)
        
        # Preview of snapshot names (more compact)
        preview_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        preview_box.set_margin_top(6)
        preview_label = Gtk.Label(label="Preview:")
        preview_label.set_size_request(60, -1)
        preview_label.set_halign(Gtk.Align.START)
        preview_box.append(preview_label)
        
        # Container for preview labels - horizontal layout
        self.preview_container = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.preview_container.set_hexpand(True)
        self.preview_container.set_halign(Gtk.Align.START)
        preview_box.append(self.preview_container)
        
        naming_box.append(preview_box)
        
        # Connect signals to update preview
        self.prefix_entry.connect("changed", self.update_snapshot_preview)
        self.format_combo.connect("notify::selected", self.update_snapshot_preview)
        
        # Note: Initial preview will be updated after all UI components are created
    
    def _create_schedule_types_section(self):
        """Create the schedule types configuration section"""
        schedule_frame = Gtk.Frame()
        schedule_frame.set_label("Snapshot Schedule Types")
        schedule_frame.set_margin_top(5)
        schedule_frame.set_margin_bottom(5)
        self.box.append(schedule_frame)
        
        schedule_types_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        schedule_types_box.set_margin_top(6)
        schedule_types_box.set_margin_bottom(6)
        schedule_types_box.set_margin_start(10)
        schedule_types_box.set_margin_end(10)
        schedule_frame.set_child(schedule_types_box)
        
        # Add explanation for schedule types (shorter)
        schedule_explanation = Gtk.Label(
            label="Select one schedule type that best fits your backup needs."
        )
        schedule_explanation.set_wrap(True)
        schedule_explanation.set_margin_bottom(6)
        schedule_explanation.set_halign(Gtk.Align.START)
        schedule_explanation.set_margin_start(0)
        schedule_explanation.add_css_class("dim-label")
        schedule_types_box.append(schedule_explanation)
        
        # Create horizontal layout for schedule types
        schedule_main_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=15)
        schedule_types_box.append(schedule_main_box)
        
        # Left column: Daily snapshots
        daily_column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        daily_column.set_hexpand(True)
        self._create_daily_section(daily_column)
        schedule_main_box.append(daily_column)
        
        # Add vertical separator
        separator = Gtk.Separator(orientation=Gtk.Orientation.VERTICAL)
        separator.set_margin_start(5)
        separator.set_margin_end(5)
        schedule_main_box.append(separator)
        
        # Right column: Weekly and Monthly
        right_column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        right_column.set_hexpand(True)
        self._create_weekly_section(right_column)
        self._create_monthly_section(right_column)
        schedule_main_box.append(right_column)
    
    def _create_daily_section(self, parent):
        """Create daily snapshots configuration"""
        daily_section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        daily_header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.daily_check = Gtk.CheckButton(label="Daily Snapshots")
        self.daily_check.connect("toggled", self.on_schedule_type_toggled)
        daily_header.append(self.daily_check)
        
        # Time selection for daily snapshots
        daily_header.append(Gtk.Label(label="at"))
        self.daily_hour_spin = Gtk.SpinButton.new_with_range(0, 23, 1)
        self.daily_hour_spin.set_value(self.config.get("daily_hour", 0))
        self.daily_hour_spin.connect("value-changed", self.update_snapshot_preview)
        self.daily_hour_spin.set_size_request(60, -1)
        daily_header.append(self.daily_hour_spin)
        daily_header.append(Gtk.Label(label=":"))
        self.daily_minute_spin = Gtk.SpinButton.new_with_range(0, 59, 1)
        self.daily_minute_spin.set_value(self.config.get("daily_minute", 0))
        self.daily_minute_spin.connect("value-changed", self.update_snapshot_preview)
        self.daily_minute_spin.set_size_request(60, -1)
        daily_header.append(self.daily_minute_spin)
        
        daily_section.append(daily_header)
        
        # Add shorter explanation for daily
        daily_explanation = Gtk.Label(label="High Protection - Best for active systems")
        daily_explanation.set_margin_start(20)
        daily_explanation.set_halign(Gtk.Align.START)
        daily_explanation.set_wrap(True)
        daily_explanation.add_css_class("dim-label")
        daily_section.append(daily_explanation)
        
        # Compact day selection buttons
        daily_button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        daily_button_box.set_margin_top(4)
        daily_button_box.set_margin_start(20)
        
        self.daily_select_all_button = Gtk.Button(label="All Days")
        self.daily_select_all_button.connect("clicked", self.on_daily_select_all_clicked)
        self.daily_select_all_button.add_css_class("pill")
        daily_button_box.append(self.daily_select_all_button)
        
        self.daily_select_none_button = Gtk.Button(label="Clear")
        self.daily_select_none_button.connect("clicked", self.on_daily_select_none_clicked)
        self.daily_select_none_button.add_css_class("pill")
        daily_button_box.append(self.daily_select_none_button)
        
        daily_section.append(daily_button_box)
        
        # Create compact day checkboxes grid
        self.daily_grid = Gtk.Grid()
        self.daily_grid.set_column_homogeneous(True)
        self.daily_grid.set_row_spacing(2)
        self.daily_grid.set_column_spacing(4)
        self.daily_grid.set_margin_start(20)
        self.daily_grid.set_margin_top(4)
        
        # Create day checkboxes in a more compact 3x3 grid (7 days total)
        days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        daily_schedule = self.config.get("daily_schedule", list(range(7)))
        
        for day_idx, day_name in enumerate(days):
            row = day_idx // 3  # 3 days per row for more compact layout
            col = day_idx % 3
            check = Gtk.CheckButton(label=day_name)
            check.set_active(day_idx in daily_schedule)
            check.connect("toggled", self.update_snapshot_preview)
            self.day_checks[day_idx] = check
            self.daily_grid.attach(check, col, row, 1, 1)
        
        daily_section.append(self.daily_grid)
        parent.append(daily_section)
    
    def _create_weekly_section(self, parent):
        """Create weekly snapshots configuration"""
        weekly_section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        
        weekly_label = Gtk.Label(label="Weekly Snapshots")
        weekly_label.set_halign(Gtk.Align.START)
        weekly_label.set_margin_start(0)
        
        self.weekly_check = Gtk.CheckButton()
        self.weekly_check.set_child(weekly_label)
        self.weekly_check.connect("toggled", self.on_schedule_type_toggled)
        weekly_section.append(self.weekly_check)
        
        # Add shorter explanation for weekly
        weekly_explanation = Gtk.Label(label="Moderate Protection - Every Monday at midnight")
        weekly_explanation.set_margin_start(20)
        weekly_explanation.set_halign(Gtk.Align.START)
        weekly_explanation.set_wrap(True)
        weekly_explanation.add_css_class("dim-label")
        weekly_section.append(weekly_explanation)
        
        parent.append(weekly_section)
    
    def _create_monthly_section(self, parent):
        """Create monthly snapshots configuration"""
        monthly_section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        
        monthly_label = Gtk.Label(label="Monthly Snapshots")
        monthly_label.set_halign(Gtk.Align.START)
        monthly_label.set_margin_start(0)
        
        self.monthly_check = Gtk.CheckButton()
        self.monthly_check.set_child(monthly_label)
        self.monthly_check.connect("toggled", self.on_schedule_type_toggled)
        monthly_section.append(self.monthly_check)
        
        # Add shorter explanation for monthly
        monthly_explanation = Gtk.Label(label="Basic Protection - 1st of each month at midnight")
        monthly_explanation.set_margin_start(20)
        monthly_explanation.set_halign(Gtk.Align.START)
        monthly_explanation.set_wrap(True)
        monthly_explanation.add_css_class("dim-label")
        monthly_section.append(monthly_explanation)
        
        parent.append(monthly_section)
    
    def _create_retention_section(self):
        """Create retention policy configuration"""
        retention_frame = Gtk.Frame()
        retention_frame.set_label("Retention Policy")
        retention_frame.set_margin_top(5)
        retention_frame.set_margin_bottom(5)
        self.box.append(retention_frame)
        
        retention_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        retention_box.set_margin_top(6)
        retention_box.set_margin_bottom(6)
        retention_box.set_margin_start(10)
        retention_box.set_margin_end(10)
        retention_frame.set_child(retention_box)
        
        retention_explanation = Gtk.Label(
            label="Specify how many snapshots of each type to keep."
        )
        retention_explanation.set_wrap(True)
        retention_explanation.set_margin_bottom(6)
        retention_explanation.set_halign(Gtk.Align.START)
        retention_explanation.set_margin_start(0)
        retention_explanation.add_css_class("dim-label")
        retention_box.append(retention_explanation)
        
        # Create horizontal layout for retention settings
        retention_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=20)
        retention_row.set_halign(Gtk.Align.START)
        retention_box.append(retention_row)
        
        # Daily retention
        daily_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        daily_label = Gtk.Label(label="Daily:")
        daily_label.set_size_request(50, -1)
        daily_label.set_halign(Gtk.Align.START)
        daily_box.append(daily_label)
        self.daily_spin = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.daily_spin.set_value(self.config.get("snapshot_retention", {}).get("daily", 7))
        self.daily_spin.set_size_request(80, -1)
        daily_box.append(self.daily_spin)
        retention_row.append(daily_box)
        
        # Weekly retention
        weekly_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        weekly_label = Gtk.Label(label="Weekly:")
        weekly_label.set_size_request(50, -1)
        weekly_label.set_halign(Gtk.Align.START)
        weekly_box.append(weekly_label)
        self.weekly_spin = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.weekly_spin.set_value(self.config.get("snapshot_retention", {}).get("weekly", 4))
        self.weekly_spin.set_size_request(80, -1)
        weekly_box.append(self.weekly_spin)
        retention_row.append(weekly_box)
        
        # Monthly retention
        monthly_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        monthly_label = Gtk.Label(label="Monthly:")
        monthly_label.set_size_request(60, -1)
        monthly_label.set_halign(Gtk.Align.START)
        monthly_box.append(monthly_label)
        self.monthly_spin = Gtk.SpinButton.new_with_range(1, 100, 1)
        self.monthly_spin.set_value(self.config.get("snapshot_retention", {}).get("monthly", 12))
        self.monthly_spin.set_size_request(80, -1)
        monthly_box.append(self.monthly_spin)
        retention_row.append(monthly_box)
    
    def _set_initial_schedule_state(self):
        """Set initial state of schedule sections"""
        # Set initial state of schedule sections - only one can be active
        daily_has_days = bool(self.config.get("daily_schedule", []))
        weekly_enabled = self.config.get("weekly_schedule", False)
        monthly_enabled = self.config.get("monthly_schedule", False)
        
        # Determine which schedule type should be active (priority: daily > weekly > monthly)
        if daily_has_days:
            self.daily_check.set_active(True)
            self.weekly_check.set_active(False)
            self.monthly_check.set_active(False)
        elif weekly_enabled:
            self.daily_check.set_active(False)
            self.weekly_check.set_active(True)
            self.monthly_check.set_active(False)
        elif monthly_enabled:
            self.daily_check.set_active(False)
            self.weekly_check.set_active(False)
            self.monthly_check.set_active(True)
        else:
            # No schedule active
            self.daily_check.set_active(False)
            self.weekly_check.set_active(False)
            self.monthly_check.set_active(False)
        
        # Initialize sensitivity based on active schedule type
        if self.daily_check.get_active():
            self.on_schedule_type_toggled(self.daily_check)
        elif self.weekly_check.get_active():
            self.on_schedule_type_toggled(self.weekly_check)
        elif self.monthly_check.get_active():
            self.on_schedule_type_toggled(self.monthly_check)
        else:
            # No schedule active, disable all controls
            for day, check in self.day_checks.items():
                check.set_sensitive(False)
            self.daily_hour_spin.set_sensitive(False)
            self.daily_minute_spin.set_sensitive(False)
            self.daily_select_all_button.set_sensitive(False)
            self.daily_select_none_button.set_sensitive(False)
        
        # Initialize sensitivity based on auto-snapshot setting
        auto_snapshot_enabled = self.config.get("auto_snapshot", True)
        if not auto_snapshot_enabled:
            self.daily_check.set_sensitive(False)
            self.weekly_check.set_sensitive(False)
            self.monthly_check.set_sensitive(False)
            
            # Disable selection buttons when auto-snapshot is disabled
            self.daily_select_all_button.set_sensitive(False)
            self.daily_select_none_button.set_sensitive(False)
                
            # Disable all day checkboxes and time selector
            for check in self.day_checks.values():
                check.set_sensitive(False)
            self.daily_hour_spin.set_sensitive(False)
            self.daily_minute_spin.set_sensitive(False)
            
            # Disable snapshot naming fields
            self.prefix_entry.set_sensitive(False)
            self.format_combo.set_sensitive(False)
            
            # Disable dataset selection when auto-snapshot is disabled
            if hasattr(self, 'datasets_list'):
                for row in self.datasets_list:
                    box = row.get_child()
                    check = box.get_first_child()
                    check.set_sensitive(False)
    
    def get_box(self):
        """Get the main container widget"""
        return self.box
    
    def update_snapshot_preview(self, widget=None):
        """Update the snapshot preview based on current settings"""
        import datetime
        
        # Safety check: ensure all required widgets exist
        if not hasattr(self, 'preview_container') or not hasattr(self, 'daily_check'):
            return
        
        # Clear existing previews
        child = self.preview_container.get_first_child()
        while child:
            self.preview_container.remove(child)
            child = self.preview_container.get_first_child()
        
        prefix = self.prefix_entry.get_text().strip() or "zfs-assistant"
        selected = self.format_combo.get_selected()
        format_options = [
            "prefix-type-timestamp", "prefix-timestamp-type", "type-prefix-timestamp", "timestamp-prefix-type"
        ]
        format_type = format_options[selected] if selected < len(format_options) else "prefix-type-timestamp"
        
        # Example timestamp
        now = datetime.datetime.now()
        timestamp = now.strftime("%Y%m%d-%H%M")
        
        # Generate examples for different snapshot types
        examples = []
        
        if self.daily_check.get_active():
            examples.append(("Daily", "daily"))
        if self.weekly_check.get_active():
            examples.append(("Weekly", "weekly"))
        if self.monthly_check.get_active():
            examples.append(("Monthly", "monthly"))
        
        if not examples:
            examples = [("Example", "manual")]
        
        for type_name, type_key in examples:
            if format_type == "prefix-type-timestamp":
                snapshot_name = f"{prefix}-{type_key}-{timestamp}"
            elif format_type == "prefix-timestamp-type":
                snapshot_name = f"{prefix}-{timestamp}-{type_key}"
            elif format_type == "type-prefix-timestamp":
                snapshot_name = f"{type_key}-{prefix}-{timestamp}"
            elif format_type == "timestamp-prefix-type":
                snapshot_name = f"{timestamp}-{prefix}-{type_key}"
            else:
                snapshot_name = f"{prefix}-{type_key}-{timestamp}"
            
            # Show only the snapshot name without type prefix for horizontal layout
            preview_label = Gtk.Label(label=snapshot_name)
            preview_label.set_halign(Gtk.Align.START)
            preview_label.add_css_class("dim-label")
            preview_label.set_margin_end(15)  # Add spacing between previews
            self.preview_container.append(preview_label)
    
    def on_schedule_switch_toggled(self, widget, state):
        """Enable or disable all schedule widgets based on auto-snapshot toggle"""
        # Update sensitivity of all schedule-related widgets
        self.daily_check.set_sensitive(state)
        self.weekly_check.set_sensitive(state)
        self.monthly_check.set_sensitive(state)
        
        # Update sensitivity of dataset selection
        if hasattr(self, 'datasets_list'):
            for row in self.datasets_list:
                box = row.get_child()
                check = box.get_first_child()
                check.set_sensitive(state)
        
        # Update sensitivity of daily buttons
        self.daily_select_all_button.set_sensitive(state)
        self.daily_select_none_button.set_sensitive(state)
            
        # Update sensitivity of daily grid and time selector
        for check in self.day_checks.values():
            check.set_sensitive(state and self.daily_check.get_active())
        self.daily_hour_spin.set_sensitive(state and self.daily_check.get_active())
        self.daily_minute_spin.set_sensitive(state and self.daily_check.get_active())
        
        # Update sensitivity of snapshot naming fields
        self.prefix_entry.set_sensitive(state)
        self.format_combo.set_sensitive(state)
        
        return False  # Allow the state change to proceed
    
    def on_schedule_type_toggled(self, button):
        """Handle schedule type checkbox toggle - make them mutually exclusive (radio button behavior)"""
        if not button.get_active():
            return  # Don't process deactivation
        
        # Deactivate all other schedule types
        if button == self.daily_check:
            self.weekly_check.set_active(False)
            self.monthly_check.set_active(False)
        elif button == self.weekly_check:
            self.daily_check.set_active(False)
            self.monthly_check.set_active(False)
        elif button == self.monthly_check:
            self.daily_check.set_active(False)
            self.weekly_check.set_active(False)
        
        # Update sensitivity based on which type is now active
        schedule_enabled = self.schedule_switch.get_active()
        
        # Daily controls
        for check in self.day_checks.values():
            check.set_sensitive(schedule_enabled and self.daily_check.get_active())
        self.daily_hour_spin.set_sensitive(schedule_enabled and self.daily_check.get_active())
        self.daily_minute_spin.set_sensitive(schedule_enabled and self.daily_check.get_active())
        self.daily_select_all_button.set_sensitive(schedule_enabled and self.daily_check.get_active())
        self.daily_select_none_button.set_sensitive(schedule_enabled and self.daily_check.get_active())
        
        # Update preview
        self.update_snapshot_preview()
    
    def on_daily_select_all_clicked(self, button):
        """Select all days"""
        for check in self.day_checks.values():
            check.set_active(True)
    
    def on_daily_select_none_clicked(self, button):
        """Deselect all days"""
        for check in self.day_checks.values():
            check.set_active(False)
    
    def on_select_all_datasets_clicked(self, button):
        """Handle select all datasets button click"""
        if hasattr(self, 'datasets_list'):
            for row in self.datasets_list:
                box = row.get_child()
                check = box.get_first_child()
                check.set_active(True)
    
    def on_select_none_datasets_clicked(self, button):
        """Handle select none datasets button click"""
        if hasattr(self, 'datasets_list'):
            for row in self.datasets_list:
                box = row.get_child()
                check = box.get_first_child()
                check.set_active(False)
    
    def apply_settings(self, config):
        """Apply settings from this tab to the config"""
        # Update managed datasets
        managed_datasets = []
        if hasattr(self, 'datasets_list'):
            for row in self.datasets_list:
                box = row.get_child()
                check = box.get_first_child()
                if check.get_active():
                    managed_datasets.append(check.get_label())
        config["datasets"] = managed_datasets
        
        # Update prefix
        prefix_value = self.prefix_entry.get_text().strip()
        if not is_safe_snapshot_prefix(prefix_value):
            prefix_value = "zfs-assistant"
        config["prefix"] = prefix_value
        
        # Update snapshot name format
        selected = self.format_combo.get_selected()
        format_options = [
            "prefix-type-timestamp", "prefix-timestamp-type", "type-prefix-timestamp", "timestamp-prefix-type"
        ]
        if selected < len(format_options):
            config["snapshot_name_format"] = format_options[selected]
        else:
            config["snapshot_name_format"] = "prefix-type-timestamp"
        
        # Update auto snapshot settings
        config["auto_snapshot"] = self.schedule_switch.get_active()
        
        # Update schedule settings (only one type can be active)
        # Clear all schedule types first
        config["daily_schedule"] = []
        config["weekly_schedule"] = False
        config["monthly_schedule"] = False
        
        # Set the active schedule type
        if self.daily_check.get_active():
            daily_schedule = []
            for day, check in self.day_checks.items():
                if check.get_active():
                    daily_schedule.append(day)
            config["daily_schedule"] = daily_schedule
            config["daily_hour"] = int(self.daily_hour_spin.get_value())
            config["daily_minute"] = int(self.daily_minute_spin.get_value())
        elif self.weekly_check.get_active():
            config["weekly_schedule"] = True
        elif self.monthly_check.get_active():
            config["monthly_schedule"] = True
        
        # Update retention policy
        config["snapshot_retention"] = {
            "daily": int(self.daily_spin.get_value()),
            "weekly": int(self.weekly_spin.get_value()),
            "monthly": int(self.monthly_spin.get_value())
        }
        
        return config
