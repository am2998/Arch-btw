#!/usr/bin/env python3
# ZFS Assistant - Maintenance Settings Tab
# Author: GitHub Copilot

import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk
try:
    from ...utils.common import is_safe_zfs_token
except Exception:
    try:
        from utils.common import is_safe_zfs_token
    except Exception:
        def is_safe_zfs_token(value):
            return bool(value and isinstance(value, str))

class MaintenanceSettingsTab:
    """System maintenance settings tab for pacman integration, system maintenance, and backup"""
    
    def __init__(self, parent_dialog):
        self.dialog = parent_dialog
        self.zfs_assistant = parent_dialog.zfs_assistant
        self.config = parent_dialog.config
        
        # Build the maintenance settings UI
        self._build_ui()
        
        # Set initial states
        self._set_initial_states()
    
    def _build_ui(self):
        """Build the maintenance settings tab UI"""
        # Create main container
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.set_margin_top(10)
        self.box.set_margin_bottom(10)
        self.box.set_margin_start(10)
        self.box.set_margin_end(10)
        
        # Pacman integration section
        self._create_pacman_section()
        
        # System maintenance section
        self._create_system_maintenance_section()
        
        # External backup section
        self._create_backup_section()
    
    def _create_pacman_section(self):
        """Create pacman integration configuration section"""
        pacman_frame = Gtk.Frame()
        pacman_frame.set_label("Pacman Integration")
        pacman_frame.set_margin_bottom(10)
        self.box.append(pacman_frame)
        
        pacman_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        pacman_box.set_margin_top(10)
        pacman_box.set_margin_bottom(10)
        pacman_box.set_margin_start(10)
        pacman_box.set_margin_end(10)
        pacman_frame.set_child(pacman_box)
        
        # Enable pacman integration
        self.pacman_switch = Gtk.Switch()
        self.pacman_switch.set_active(self.config.get("pacman_integration", True))
        self.pacman_switch.connect("state-set", self.on_pacman_switch_toggled)
        pacman_enable_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        pacman_enable_box.append(Gtk.Label(label="Create Snapshots Before Pacman Operations:"))
        pacman_enable_box.append(self.pacman_switch)
        pacman_box.append(pacman_enable_box)
        
        # Info about pacman hook
        pacman_info = Gtk.Label(label="This will create snapshots before package installations\nand removals via pacman (excludes system maintenance).")
        pacman_info.set_halign(Gtk.Align.START)
        pacman_info.set_margin_start(0)  # Align with frame content
        pacman_info.set_margin_top(5)
        pacman_info.add_css_class("dim-label")
        pacman_box.append(pacman_info)
        
        # Pacman snapshot name preview
        pacman_preview_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        pacman_preview_box.set_halign(Gtk.Align.START)
        pacman_preview_box.set_margin_top(10)
        pacman_preview_label = Gtk.Label(label="Preview:")
        pacman_preview_label.set_size_request(70, -1)
        pacman_preview_label.set_halign(Gtk.Align.START)
        pacman_preview_box.append(pacman_preview_label)
        
        self.pacman_preview_label = Gtk.Label()
        self.pacman_preview_label.set_halign(Gtk.Align.START)
        self.pacman_preview_label.add_css_class("dim-label")
        pacman_preview_box.append(self.pacman_preview_label)
        pacman_box.append(pacman_preview_box)
        
        # Update pacman preview
        self.update_pacman_preview()
    
    def _create_system_maintenance_section(self):
        """Create system maintenance configuration section"""
        updates_frame = Gtk.Frame()
        updates_frame.set_label("Scheduled System Maintenance")
        updates_frame.set_margin_top(10)
        updates_frame.set_margin_bottom(10)
        self.box.append(updates_frame)
        
        updates_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        updates_box.set_margin_top(10)
        updates_box.set_margin_bottom(10)
        updates_box.set_margin_start(10)
        updates_box.set_margin_end(10)
        updates_frame.set_child(updates_box)
        
        # Update options
        updates_info = Gtk.Label(label="System maintenance (pacman -Syu + flatpak update + cache cleanup + orphan removal) is ONLY available during scheduled snapshots.\nThis ensures system consistency and rollback capabilities. Choose when to create snapshots relative to maintenance:")
        updates_info.set_halign(Gtk.Align.START)
        updates_info.set_margin_bottom(15)  # Better spacing before radio buttons
        updates_info.set_margin_start(0)   # Align with frame content
        updates_info.add_css_class("dim-label")
        updates_box.append(updates_info)
        
        # Radio button for disabled updates
        self.update_disabled_radio = Gtk.CheckButton(label="Do not execute system maintenance during snapshots")
        self.update_disabled_radio.connect("toggled", self.on_update_option_toggled)
        updates_box.append(self.update_disabled_radio)
        
        # Radio button for full system update (pacman + flatpak)
        self.update_before_radio = Gtk.CheckButton(label="Enable full system maintenance (pacman updates + flatpak updates + cache cleanup + orphan removal) during snapshots")
        self.update_before_radio.connect("toggled", self.on_update_option_toggled)
        updates_box.append(self.update_before_radio)
        
        # Radio button for pacman-only updates
        self.update_pacman_only_radio = Gtk.CheckButton(label="Enable pacman-only maintenance (pacman updates + cache cleanup + orphan removal, no flatpak) during snapshots")
        self.update_pacman_only_radio.connect("toggled", self.on_update_option_toggled)
        updates_box.append(self.update_pacman_only_radio)
        
        # Clean cache option
        clean_cache_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        clean_cache_box.set_margin_start(0)  # Align with frame content
        clean_cache_box.set_margin_top(10)    # Better spacing from radio buttons
        
        self.clean_cache_check = Gtk.CheckButton(label="Clean package caches after maintenance (pacman + flatpak)")
        self.clean_cache_check.set_active(self.config.get("clean_cache_after_updates", False))
        clean_cache_box.append(self.clean_cache_check)
        updates_box.append(clean_cache_box)
        
        # Set initial state based on config
        update_option = self.config.get("update_snapshots", "disabled")
        if update_option == "disabled":
            self.update_disabled_radio.set_active(True)
            self.clean_cache_check.set_sensitive(False)
        elif update_option == "enabled":
            self.update_before_radio.set_active(True)
            self.clean_cache_check.set_sensitive(True)
        elif update_option == "pacman_only":
            self.update_pacman_only_radio.set_active(True)
            self.clean_cache_check.set_sensitive(True)
        else:
            # Default to disabled if invalid value
            self.update_disabled_radio.set_active(True)
            self.clean_cache_check.set_sensitive(False)
    
    def _create_backup_section(self):
        """Create external backup configuration section"""
        backup_frame = Gtk.Frame()
        backup_frame.set_label("External Backup Pool")
        backup_frame.set_margin_top(10)
        backup_frame.set_margin_bottom(10)
        self.box.append(backup_frame)
        
        backup_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        backup_box.set_margin_top(10)
        backup_box.set_margin_bottom(10)
        backup_box.set_margin_start(10)
        backup_box.set_margin_end(10)
        backup_frame.set_child(backup_box)
        
        # Enable external backup
        self.backup_switch = Gtk.Switch()
        self.backup_switch.set_active(self.config.get("external_backup_enabled", False))
        self.backup_switch.connect("state-set", self.on_backup_switch_toggled)
        backup_enable_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        backup_enable_box.append(Gtk.Label(label="Enable External Backup:"))
        backup_enable_box.append(self.backup_switch)
        backup_box.append(backup_enable_box)
        
        # Info about external backup
        backup_info = Gtk.Label(label="Send snapshots to an external ZFS pool for backup purposes.\nSnapshots will be replicated using 'zfs send' and 'zfs receive'.")
        backup_info.set_halign(Gtk.Align.START)
        backup_info.set_margin_start(0)
        backup_info.set_margin_top(5)
        backup_info.add_css_class("dim-label")
        backup_box.append(backup_info)
        
        # External pool name entry
        pool_entry_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        pool_entry_box.set_margin_top(10)
        pool_label = Gtk.Label(label="External Pool Name:")
        pool_label.set_size_request(140, -1)
        pool_label.set_halign(Gtk.Align.START)
        pool_entry_box.append(pool_label)
        
        self.external_pool_entry = Gtk.Entry()
        self.external_pool_entry.set_text(self.config.get("external_pool_name", ""))
        self.external_pool_entry.set_size_request(200, -1)
        self.external_pool_entry.set_placeholder_text("e.g., backup_pool")
        pool_entry_box.append(self.external_pool_entry)
        
        # Test connection button
        self.test_pool_button = Gtk.Button(label="Test Pool Connection")
        self.test_pool_button.connect("clicked", self.on_test_pool_clicked)
        pool_entry_box.append(self.test_pool_button)
        
        backup_box.append(pool_entry_box)
        
        # Backup schedule options
        backup_schedule_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        backup_schedule_box.set_margin_top(10)
        backup_schedule_label = Gtk.Label(label="Backup Frequency:")
        backup_schedule_label.set_size_request(140, -1)
        backup_schedule_label.set_halign(Gtk.Align.START)
        backup_schedule_box.append(backup_schedule_label)
        
        self.backup_frequency_combo = Gtk.DropDown()
        backup_frequency_model = Gtk.StringList.new([
            "Follow snapshot schedule",
            "Manual"
        ])
        self.backup_frequency_combo.set_model(backup_frequency_model)
        
        # Set current backup frequency
        current_frequency = self.config.get("backup_frequency", "Manual")
        frequency_options = ["Follow snapshot schedule", "Manual"]
        try:
            current_index = frequency_options.index(current_frequency)
            self.backup_frequency_combo.set_selected(current_index)
        except ValueError:
            self.backup_frequency_combo.set_selected(1)  # Default to "Manual"
        
        self.backup_frequency_combo.set_size_request(150, -1)
        backup_schedule_box.append(self.backup_frequency_combo)
        backup_box.append(backup_schedule_box)
    
    def _set_initial_states(self):
        """Set initial sensitivity states based on configuration"""
        # Initialize backup section sensitivity
        self.on_backup_switch_toggled(self.backup_switch, self.backup_switch.get_active())
        
        # Enforce mutual exclusivity between pacman integration and system updates
        pacman_enabled = self.config.get("pacman_integration", True)
        update_option = self.config.get("update_snapshots", "disabled")
        
        if pacman_enabled and update_option != "disabled":
            # If both are enabled in config, prioritize pacman and disable updates
            self.update_disabled_radio.set_active(True)
            self.update_before_radio.set_active(False)
            self.update_pacman_only_radio.set_active(False)
            self.clean_cache_check.set_sensitive(False)
            update_option = "disabled"
        
        # Set initial sensitivity based on mutual exclusivity
        if pacman_enabled:
            self.update_disabled_radio.set_sensitive(False)
            self.update_before_radio.set_sensitive(False)
            self.update_pacman_only_radio.set_sensitive(False)
            self.clean_cache_check.set_sensitive(False)
        elif update_option != "disabled":
            self.pacman_switch.set_sensitive(False)
    
    def get_box(self):
        """Get the main container widget"""
        return self.box
    
    def update_pacman_preview(self):
        """Update the pacman snapshot preview"""
        import datetime
        
        prefix = "zfs-assistant"  # Use default prefix for pacman operations
        timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
        snapshot_name = f"{prefix}-pkgop-{timestamp}"
        
        self.pacman_preview_label.set_text(snapshot_name)
    
    def update_clean_cache_sensitivity(self):
        """Update clean cache checkbox sensitivity based on current state"""
        # Clean cache is only available when system updates are enabled
        update_enabled = (self.update_before_radio.get_active() or 
                         self.update_pacman_only_radio.get_active())
        self.clean_cache_check.set_sensitive(update_enabled)
    
    def on_pacman_switch_toggled(self, widget, state):
        """Handle pacman integration toggle - make mutually exclusive with system updates"""
        if state:
            # If enabling pacman integration, disable system updates
            self.update_disabled_radio.set_active(True)
            self.update_before_radio.set_active(False)
            self.update_pacman_only_radio.set_active(False)
            
            # Disable system update controls
            self.update_disabled_radio.set_sensitive(False)
            self.update_before_radio.set_sensitive(False)
            self.update_pacman_only_radio.set_sensitive(False)
        else:
            # If disabling pacman integration, enable system update controls
            self.update_disabled_radio.set_sensitive(True)
            self.update_before_radio.set_sensitive(True)
            self.update_pacman_only_radio.set_sensitive(True)
        
        # Update pacman preview
        self.update_pacman_preview()
        
        # Update clean cache sensitivity when pacman integration changes
        self.update_clean_cache_sensitivity()
        
        return False
    
    def on_update_option_toggled(self, widget):
        """Handle system maintenance option toggle"""
        if not widget.get_active():
            return  # Only process activation
        
        # Make radio buttons mutually exclusive
        if widget == self.update_disabled_radio:
            self.update_before_radio.set_active(False)
            self.update_pacman_only_radio.set_active(False)
            # Enable pacman integration when maintenance is disabled
            self.pacman_switch.set_sensitive(True)
        elif widget == self.update_before_radio:
            self.update_disabled_radio.set_active(False)
            self.update_pacman_only_radio.set_active(False)
            # Disable pacman integration when maintenance is enabled
            self.pacman_switch.set_active(False)
            self.pacman_switch.set_sensitive(False)
        elif widget == self.update_pacman_only_radio:
            self.update_disabled_radio.set_active(False)
            self.update_before_radio.set_active(False)
            # Disable pacman integration when maintenance is enabled
            self.pacman_switch.set_active(False)
            self.pacman_switch.set_sensitive(False)
        
        # Update clean cache sensitivity
        self.update_clean_cache_sensitivity()
    
    def on_backup_switch_toggled(self, widget, state):
        """Handle backup enable/disable toggle"""
        self.external_pool_entry.set_sensitive(state)
        self.test_pool_button.set_sensitive(state)
        self.backup_frequency_combo.set_sensitive(state)
        
        return False
    
    def on_test_pool_clicked(self, button):
        """Handle test pool connection button click"""
        pool_name = self.external_pool_entry.get_text().strip()
        if not pool_name:
            self._show_message_dialog("Error", "Please enter a pool name to test.")
            return
        if not is_safe_zfs_token(pool_name):
            self._show_message_dialog("Error", "Invalid pool name format.")
            return
        
        # Test if the pool exists
        import subprocess
        try:
            result = subprocess.run(['zfs', 'list', pool_name], 
                                  capture_output=True, text=True, check=True)
            self._show_message_dialog("Success", f"Pool '{pool_name}' is accessible and ready for backup.")
        except subprocess.CalledProcessError:
            self._show_message_dialog("Error", f"Pool '{pool_name}' not found or not accessible.\nMake sure the pool exists and is imported.")
        except Exception as e:
            self._show_message_dialog("Error", f"Error testing pool connection: {str(e)}")
    
    def _show_message_dialog(self, title, message):
        """Show a simple message dialog"""
        dialog = Gtk.MessageDialog(
            transient_for=self.dialog,
            modal=True,
            message_type=Gtk.MessageType.INFO if title == "Success" else Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text=title,
            secondary_text=message
        )
        dialog.connect("response", lambda d, r: d.destroy())
        dialog.present()
    
    def apply_settings(self, config):
        """Apply settings from this tab to the config"""
        # Update pacman integration
        config["pacman_integration"] = self.pacman_switch.get_active()
        
        # Update system maintenance snapshots option
        if self.update_disabled_radio.get_active():
            config["update_snapshots"] = "disabled"
        elif self.update_before_radio.get_active():
            config["update_snapshots"] = "enabled"
        elif self.update_pacman_only_radio.get_active():
            config["update_snapshots"] = "pacman_only"
        else:
            # Default to "disabled" if none is selected
            config["update_snapshots"] = "disabled"
        
        # Update clean cache option
        config["clean_cache_after_updates"] = self.clean_cache_check.get_active()
        
        # Update external backup settings
        config["external_backup_enabled"] = self.backup_switch.get_active()
        config["external_pool_name"] = self.external_pool_entry.get_text().strip()
        
        # Update backup frequency
        backup_selected = self.backup_frequency_combo.get_selected()
        frequency_options = ["Follow snapshot schedule", "Manual"]
        if backup_selected < len(frequency_options):
            config["backup_frequency"] = frequency_options[backup_selected]
        else:
            config["backup_frequency"] = "Manual"
        
        return config
