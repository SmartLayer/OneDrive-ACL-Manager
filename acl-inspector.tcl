#!/usr/bin/env tclsh
#
# OneDrive ACL Lister - Tcl/Tk GUI Version with Command Line Support
# Using rclone.conf token to access Microsoft Graph API directly
#
# This script demonstrates how to:
# 1. Read the OAuth token from rclone.conf
# 2. Use it to make direct Microsoft Graph API calls
# 3. Display ACL (Access Control List) in a treeview widget or console
#
# Prerequisites:
# - rclone must be installed and configured with OneDrive remote
# - tls package for HTTPS requests (package require tls)
# - Valid OAuth token in ~/.config/rclone/rclone.conf
#
# Usage:
#    GUI mode:    wish acl_demo.tcl [item_path] [remote_name]
#    CLI mode:    tclsh acl_demo.tcl <item_path> [remote_name]
#    
#    item_path: Required. Path to the folder or file in OneDrive
#    remote_name: Optional. Name of the OneDrive remote (default: OneDrive)
#
# Example:
#    wish acl_demo.tcl "Documents"
#    tclsh acl_demo.tcl "Documents/Project" "MyOneDrive"

# Check if we're running in GUI mode (wish) or CLI mode (tclsh)
set gui_mode [expr {[info commands tk] ne ""}]

if {$gui_mode} {
    package require Tk
    package require Ttk
}

package require http
package require json
package require json::write
package require tls

# Configure TLS for HTTPS requests
::http::register https 443 [list ::tls::socket -autoservername 1]

# Suppress TLS channel error messages (they're just warnings, not fatal)
# These get logged but don't affect functionality
proc bgerror {message} {
    # Suppress SSL channel errors (non-fatal warnings)
    if {[string match "*SSL channel*" $message]} {
        return
    }
    # Log other errors only if debug mode is on
    debug_log "Background error: $message"
}

# Global variables
set debug_mode 0  ;# Set to 1 to enable debug logging
set access_token ""
set item_path ""
set remote_name "OneDrive"
set current_folder_id "root"
set current_folder_path ""
set acl_fetch_job ""  ;# Track pending ACL fetch job to allow cancellation
set token_capability "unknown"  ;# "full", "read-only", or "unknown"
set current_item_id ""       ;# Track current item for edit operations

# OAuth configuration
set ::oauth(client_id)     "b15665d9-eda6-4092-8539-0eec376afd59"
set ::oauth(client_secret) "qtyfaBBYA403=unZUP40~_#"
set ::oauth(redirect_uri)  "http://localhost:53682/"
set ::oauth(auth_url)      "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
set ::oauth(token_url)     "https://login.microsoftonline.com/common/oauth2/v2.0/token"
set ::oauth(scope)         "Files.Read Files.ReadWrite Files.ReadWrite.All Sites.Manage.All offline_access"
set ::oauth(auth_code)     ""
set ::serverSock           ""
set ::oauth_modal_result   0  ;# Result from OAuth modal dialog (0=failure/cancel, 1=success)

# GUI widget variables (will be set in GUI mode)
set remote_entry ""
set url_entry ""
set action_buttons_frame ""

# Multi-column browser variables
set column_list {}        ;# List of column widgets
set column_data {}        ;# List of column data (each element: {folder_id path items})
set selected_item {}      ;# Currently selected item {col_index item_index item_data}
set fetch_button ""       ;# Fetch ACL button widget
set acl_path_label ""     ;# Label showing path of current ACL display

if {$gui_mode} {
    # Declare global widget variables
    global remote_entry url_entry fetch_button acl_path_label column_list column_data selected_item action_buttons_frame
    
    # Create main window
    wm title . "OneDrive ACL Lister"

    # Handle window close during OAuth flow
    wm protocol . WM_DELETE_WINDOW {
        global serverSock oauth
        
        # Clean up OAuth server if running
        if {[info exists serverSock] && $serverSock ne ""} {
            catch {close $serverSock}
            set serverSock ""
            debug_log "Closed OAuth server socket due to window close"
        }
        
        # Signal OAuth flow to stop by setting a cancel flag
        if {[info exists oauth(auth_code)] && $oauth(auth_code) eq ""} {
            set oauth(auth_code) "CANCELLED"
            debug_log "OAuth flow cancelled by user (window closed)"
        }
        
        # Exit cleanly
        destroy .
    }

    # Create main frame
    set main_frame [ttk::frame .main]
    pack $main_frame -fill both -expand yes -padx 10 -pady 10

    # Create input frame (top section)
    set input_frame [ttk::frame $main_frame.input]
    pack $input_frame -fill x -pady {0 10}

    # OneDrive URL address bar (read-only, at top)
    set url_frame [ttk::frame $input_frame.url]
    pack $url_frame -fill x -pady 2
    ttk::label $url_frame.label -text "URL:"
    pack $url_frame.label -side left
    set url_entry [ttk::entry $url_frame.entry -width 60]
    pack $url_entry -side left -fill x -expand yes -padx {5 0}
    $url_entry insert 0 "https://onedrive.live.com/?id=root"
    $url_entry configure -state readonly
    
    # Hidden remote name entry (for rclone configuration)
    set remote_entry [ttk::entry $input_frame.remote_hidden -width 20]
    $remote_entry insert 0 "OneDrive"
    # Don't pack this - it's hidden

    # Multi-column browser frame
    set browser_frame [ttk::frame $main_frame.browser]
    pack $browser_frame -fill both -expand yes -pady {0 10}

    ttk::label $browser_frame.label -text "Browse OneDrive:"
    pack $browser_frame.label -anchor w -pady {0 5}

    # Create canvas and scrollbar for horizontal scrolling
    set browser_canvas [canvas $browser_frame.canvas -height 300 -highlightthickness 0]
    set browser_scroll [ttk::scrollbar $browser_frame.scroll -orient horizontal -command "$browser_canvas xview"]
    pack $browser_scroll -side bottom -fill x
    pack $browser_canvas -side top -fill both -expand yes
    $browser_canvas configure -xscrollcommand "$browser_scroll set"

    # Create frame inside canvas to hold columns
    set columns_container [ttk::frame $browser_canvas.columns]
    $browser_canvas create window 0 0 -anchor nw -window $columns_container

    # Bind canvas resize to update scroll region
    bind $columns_container <Configure> {
        .main.browser.canvas configure -scrollregion [.main.browser.canvas bbox all]
    }

    # Fetch button frame (between browser and ACL display)
    set fetch_frame [ttk::frame $main_frame.fetch]
    pack $fetch_frame -fill x -pady {5 10}
    
    set fetch_button [ttk::button $fetch_frame.button -text "Fetch ACL" -command on_fetch_button_click -state disabled]
    pack $fetch_button -side left -padx 5
    
    # Action buttons on the right side
    set action_buttons_frame [ttk::frame $fetch_frame.actions]
    pack $action_buttons_frame -side right -padx 5
    
    ttk::button $action_buttons_frame.remove -text "Remove Selected" -command on_remove_selected_click -state disabled
    ttk::button $action_buttons_frame.invite -text "Invite User" -command on_invite_user_click -state disabled
    
    pack $action_buttons_frame.remove -side left -padx 2
    pack $action_buttons_frame.invite -side left -padx 2

    # ACL display section (lower half)
    set acl_section [ttk::frame $main_frame.acl]
    pack $acl_section -fill both -expand yes

    # ACL path label (shows which item's ACL is displayed)
    set acl_path_frame [ttk::frame $acl_section.path]
    pack $acl_path_frame -fill x -pady {0 5}
    ttk::label $acl_path_frame.label -text "ACL for:"
    pack $acl_path_frame.label -side left
    set acl_path_label [ttk::entry $acl_path_frame.entry]
    pack $acl_path_label -side left -fill x -expand yes -padx {5 0}
    $acl_path_label configure -state readonly

    # Status label
    set status_label [ttk::label $acl_section.status -text "Ready" -foreground blue]
    pack $status_label -fill x -pady {0 10}

    # Create treeview frame
    set tree_frame [ttk::frame $acl_section.tree]
    pack $tree_frame -fill both -expand yes

    # Create treeview with scrollbars
    set tree_container [ttk::frame $tree_frame.container]
    pack $tree_container -fill both -expand yes

    # Treeview widget (with multi-select enabled)
    set tree [ttk::treeview $tree_container.tree -columns {id roles user email link_type link_scope expires} -show {tree headings} -selectmode extended -height 10]
    pack $tree -side left -fill both -expand yes

    # Scrollbars
    set v_scrollbar [ttk::scrollbar $tree_container.vscroll -orient vertical -command "$tree yview"]
    pack $v_scrollbar -side right -fill y
    $tree configure -yscrollcommand "$v_scrollbar set"

    set h_scrollbar [ttk::scrollbar $tree_frame.hscroll -orient horizontal -command "$tree xview"]
    pack $h_scrollbar -fill x
    $tree configure -xscrollcommand "$h_scrollbar set"

    # Configure treeview columns
    $tree heading #0 -text ""
    $tree column #0 -width 100 -minwidth 80

    $tree heading id -text "ID"
    $tree column id -width 200 -minwidth 150

    $tree heading roles -text "Roles"
    $tree column roles -width 80 -minwidth 60

    $tree heading user -text "User"
    $tree column user -width 150 -minwidth 100

    $tree heading email -text "Email"
    $tree column email -width 200 -minwidth 150

    $tree heading link_type -text "Link Type"
    $tree column link_type -width 80 -minwidth 60

    $tree heading link_scope -text "Link Scope"
    $tree column link_scope -width 80 -minwidth 60

    $tree heading expires -text "Expires"
    $tree column expires -width 120 -minwidth 100

    # Configure tags for different permission types
    $tree tag configure owner -background lightgreen
    $tree tag configure write -background lightblue
    $tree tag configure read -background lightyellow
    
    # Fix Treeview row height to match font (prevents text clipping on Linux HiDPI)
    set f [ttk::style lookup Treeview -font]
    if {$f eq ""} { set f TkDefaultFont }
    set h [expr {[font metrics $f -linespace] + 6}]  ;# a bit of padding
    ttk::style configure Treeview -rowheight $h
}

# ============================================================================
# Utility Functions
# ============================================================================

proc debug_log {message} {
    global debug_mode
    if {$debug_mode} {
        puts "DEBUG: $message"
        
        # Also write to debug.log file
        if {[catch {
            set fh [open "debug.log" a]
            puts $fh "DEBUG: $message"
            close $fh
        }]} {
            # Silently ignore file write errors
        }
    }
}

# ============================================================================
# Multi-Column Browser Functions
# ============================================================================

proc create_column {col_index} {
    # Create a new column listbox at the specified index
    global column_list
    
    set container .main.browser.canvas.columns
    set col_frame [ttk::frame $container.col$col_index -relief ridge -borderwidth 1]
    pack $col_frame -side left -fill both -expand yes -padx 2
    
    set listbox [listbox $col_frame.list -width 25 -height 15]
    set scrollbar [ttk::scrollbar $col_frame.scroll -orient vertical -command "$listbox yview"]
    pack $scrollbar -side right -fill y
    pack $listbox -side left -fill both -expand yes
    $listbox configure -yscrollcommand "$scrollbar set"
    
    # Bind single click event
    bind $listbox <Button-1> [list on_column_item_click $col_index %W %y]
    
    lappend column_list $listbox
    
    return $listbox
}

proc destroy_columns_after {col_index} {
    # Remove all columns after the specified index
    global column_list column_data
    
    set num_columns [llength $column_list]
    
    for {set i [expr $col_index + 1]} {$i < $num_columns} {incr i} {
        set listbox [lindex $column_list $i]
        set frame [winfo parent $listbox]
        destroy $frame
    }
    
    # Update column_list and column_data
    set column_list [lrange $column_list 0 $col_index]
    set column_data [lrange $column_data 0 $col_index]
}

proc populate_column {col_index folder_id folder_path} {
    # Populate a column with the contents of a folder
    global column_list column_data access_token remote_entry
    
    debug_log "Populating column $col_index with folder: $folder_path (ID: $folder_id)"
    
    # Ensure we have enough columns
    while {[llength $column_list] <= $col_index} {
        create_column [llength $column_list]
    }
    
    set listbox [lindex $column_list $col_index]
    $listbox delete 0 end
    $listbox insert end "Loading..."
    update
    
    # Get access token (any capability is fine for browsing)
    set result [get_access_token_with_capability [$remote_entry get] ""]
    set access_token [lindex $result 0]
    set capability [lindex $result 1]
    
    if {$access_token eq ""} {
        $listbox delete 0 end
        $listbox insert end "❌ No access token"
        return
    }
    
    # Fetch folder contents from OneDrive API
    set headers [list Authorization "Bearer $access_token"]
    if {$folder_id eq "root"} {
        set children_url "https://graph.microsoft.com/v1.0/me/drive/root/children"
    } else {
        set children_url "https://graph.microsoft.com/v1.0/me/drive/items/$folder_id/children"
    }
    
    set result [make_http_request $children_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status eq "200"} {
        $listbox delete 0 end
        
        set children_dict [json::json2dict $data]
        set children [dict get $children_dict value]
        
        # Store items data for this column
        set items_data {}
        
        # Sort: folders first, then files
        set folders {}
        set files {}
        
        foreach child $children {
            set child_name [dict get $child name]
            set child_id [dict get $child id]
            set is_folder [dict exists $child folder]
            
            set item_data [dict create \
                name $child_name \
                id $child_id \
                is_folder $is_folder \
                path [expr {$folder_path eq "" ? $child_name : "$folder_path/$child_name"}]]
            
            if {$is_folder} {
                lappend folders $item_data
            } else {
                lappend files $item_data
            }
        }
        
        # Add folders first
        foreach item $folders {
            set name [dict get $item name]
            $listbox insert end "📁 $name"
            lappend items_data $item
        }
        
        # Add files
        foreach item $files {
            set name [dict get $item name]
            $listbox insert end "📄 $name"
            lappend items_data $item
        }
        
        # Update column_data
        while {[llength $column_data] <= $col_index} {
            lappend column_data {}
        }
        set column_data [lreplace $column_data $col_index $col_index \
            [dict create folder_id $folder_id path $folder_path items $items_data]]
        
        debug_log "Column $col_index populated with [llength $items_data] items"
    } else {
        $listbox delete 0 end
        $listbox insert end "❌ Error loading"
    }
}

proc on_column_item_click {col_index widget y_coord} {
    # Handle click on an item in a column
    global column_data selected_item url_entry fetch_button
    
    # Get the index of the clicked item
    set item_index [$widget nearest $y_coord]
    if {$item_index < 0} {
        return
    }
    
    # Select the item in the listbox
    $widget selection clear 0 end
    $widget selection set $item_index
    
    # Get the item data
    set col_data [lindex $column_data $col_index]
    set items [dict get $col_data items]
    set item [lindex $items $item_index]
    
    set item_name [dict get $item name]
    set item_id [dict get $item id]
    set item_path [dict get $item path]
    set is_folder [dict get $item is_folder]
    
    debug_log "Clicked: $item_path (folder: $is_folder)"
    
    # Update selected item
    set selected_item [dict create \
        col_index $col_index \
        item_index $item_index \
        id $item_id \
        path $item_path \
        name $item_name \
        is_folder $is_folder]
    
    # Update URL bar
    $url_entry configure -state normal
    $url_entry delete 0 end
    $url_entry insert 0 "https://onedrive.live.com/?id=$item_id"
    $url_entry configure -state readonly
    
    # Enable fetch button
    $fetch_button configure -state normal
    
    # If it's a folder, destroy columns after this one and create a new column
    if {$is_folder} {
        destroy_columns_after $col_index
        populate_column [expr $col_index + 1] $item_id $item_path
    } else {
        # If it's a file, just destroy columns after this one
        destroy_columns_after $col_index
    }
}

proc on_fetch_button_click {} {
    # Fetch ACL for the currently selected item
    global selected_item acl_path_label
    
    if {[llength $selected_item] == 0} {
        update_status "No item selected" red
        return
    }
    
    set item_path [dict get $selected_item path]
    
    # Update ACL path label
    $acl_path_label configure -state normal
    $acl_path_label delete 0 end
    $acl_path_label insert 0 $item_path
    $acl_path_label configure -state readonly
    
    # Fetch ACL
    fetch_acl $item_path
}

# ============================================================================
# Utility Functions
# ============================================================================


proc url_encode {path} {
    # URL encode a path, handling Unicode characters properly
    set encoded ""
    foreach char [split $path ""] {
        if {$char eq " "} {
            append encoded "%20"
        } elseif {$char eq "/"} {
            append encoded "/"
        } elseif {[string is ascii $char] && ([string is alnum $char] || $char eq "-" || $char eq "_" || $char eq ".")} {
            append encoded $char
        } else {
            # For non-ASCII characters, use proper UTF-8 encoding
            set utf8_bytes [encoding convertto utf-8 $char]
            foreach byte [split $utf8_bytes ""] {
                append encoded [format "%%%02X" [scan $byte %c]]
            }
        }
    }
    return $encoded
}

proc extract_user_info {perm} {
    # Extract user display name and email from a permission object
    # Returns {displayName email} or {"N/A" "N/A"}
    if {[dict exists $perm grantedTo user]} {
        set user [dict get $perm grantedTo user]
        return [list [dict get $user displayName] [dict get $user email]]
    } elseif {[dict exists $perm grantedToIdentities]} {
        set identities [dict get $perm grantedToIdentities]
        if {[llength $identities] > 0} {
            set identity [lindex $identities 0]
            if {[dict exists $identity user]} {
                set user [dict get $identity user]
                return [list [dict get $user displayName] [dict get $user email]]
            }
        }
    }
    return [list "N/A" "N/A"]
}

proc is_owner_permission {perm} {
    # Check if permission has owner role
    set roles [dict get $perm roles]
    return [expr {[lsearch $roles "owner"] >= 0}]
}

proc is_inherited_permission {perm} {
    # Check if permission is inherited
    return [dict exists $perm inheritedFrom]
}

proc build_graph_api_url {endpoint} {
    # Build Microsoft Graph API URL
    return "https://graph.microsoft.com/v1.0$endpoint"
}

proc get_item_url_from_path {path} {
    # Get Microsoft Graph API URL for an item by path
    # Handles root path and regular paths with proper URL encoding
    # Returns: Full Graph API URL for the item
    if {$path eq "/" || $path eq ""} {
        return [build_graph_api_url "/me/drive/root"]
    } else {
        set encoded_path [url_encode $path]
        return [build_graph_api_url "/me/drive/root:/$encoded_path"]
    }
}

# ============================================================================
# Core Functions
# ============================================================================

proc update_status {message {color blue}} {
    global status_label gui_mode
    # Always log to console for debugging
    puts "STATUS ($color): $message"
    if {$gui_mode} {
        $status_label configure -text $message -foreground $color
    }
}

proc clear_treeview {} {
    global tree gui_mode
    if {$gui_mode} {
        foreach item [$tree children {}] {
            $tree delete $item
        }
        update_status "Treeview cleared" green
    }
}

proc display_acl_cli {permissions item_id} {
    set perm_count [llength $permissions]
    puts "\n=== ACL Information ==="
    puts "Folder ID: $item_id"
    puts "Found $perm_count permission(s):"
    puts ""
    
    # Print table header
    puts [format "%-4s %-15s %-25s %-30s" "No." "Role" "User" "Email"]
    puts [string repeat "-" 80]
    
    set perm_num 1
    foreach perm $permissions {
        set roles [dict get $perm roles]
        set roles_str [join $roles ", "]
        
        # Get user information
        lassign [extract_user_info $perm] user_name user_email
        
        # Truncate long names/emails for table format
        if {[string length $user_name] > 24} {
            set user_name "[string range $user_name 0 21]..."
        }
        if {[string length $user_email] > 29} {
            set user_email "[string range $user_email 0 26]..."
        }
        
        puts [format "%-4d %-15s %-25s %-30s" $perm_num $roles_str $user_name $user_email]
        
        incr perm_num
    }
    puts ""
}

# ============================================================================
# Recursive ACL Display Functions
# ============================================================================

proc get_user_role_from_permissions {permissions user_email} {
    # Extract the role for a specific user from a permission list
    # Returns: "write", "read", or ""
    set user_email_lower [string tolower $user_email]
    
    foreach perm $permissions {
        # Skip owner permissions
        if {[is_owner_permission $perm]} {
            continue
        }
        
        # Check grantedTo user
        if {[dict exists $perm grantedTo user]} {
            set user [dict get $perm grantedTo user]
            set email [string tolower [dict get $user email]]
            if {$email eq $user_email_lower} {
                set roles [dict get $perm roles]
                if {[lsearch -exact $roles "write"] >= 0} {
                    return "write"
                } elseif {[lsearch -exact $roles "read"] >= 0} {
                    return "read"
                }
                return [lindex $roles 0]
            }
        }
        
        # Check grantedToIdentities (OneDrive Business)
        if {[dict exists $perm grantedToIdentities]} {
            set identities [dict get $perm grantedToIdentities]
            foreach identity $identities {
                if {[dict exists $identity user]} {
                    set user [dict get $identity user]
                    set email [string tolower [dict get $user email]]
                    if {$email eq $user_email_lower} {
                        set roles [dict get $perm roles]
                        if {[lsearch -exact $roles "write"] >= 0} {
                            return "write"
                        } elseif {[lsearch -exact $roles "read"] >= 0} {
                            return "read"
                        }
                        return [lindex $roles 0]
                    }
                }
            }
        }
    }
    return ""
}

proc extract_users_from_permissions {permissions} {
    # Extract all non-owner users from permissions
    # Returns: list of {email role} pairs
    set users_dict {}
    
    foreach perm $permissions {
        # Skip owner permissions
        if {[is_owner_permission $perm]} {
            continue
        }
        
        set roles [dict get $perm roles]
        set role "read"
        if {[lsearch -exact $roles "write"] >= 0} {
            set role "write"
        } elseif {[llength $roles] > 0} {
            set role [lindex $roles 0]
        }
        
        # Check grantedTo user
        if {[dict exists $perm grantedTo user]} {
            set user [dict get $perm grantedTo user]
            set email [string tolower [dict get $user email]]
            if {$email ne ""} {
                dict set users_dict $email $role
            }
        }
        
        # Check grantedToIdentities (OneDrive Business)
        if {[dict exists $perm grantedToIdentities]} {
            set identities [dict get $perm grantedToIdentities]
            foreach identity $identities {
                if {[dict exists $identity user]} {
                    set user [dict get $identity user]
                    set email [string tolower [dict get $user email]]
                    if {$email ne ""} {
                        dict set users_dict $email $role
                    }
                }
            }
        }
    }
    
    return $users_dict
}

proc compare_permission_sets {child_users_dict parent_users_dict} {
    # Compare two permission sets to determine inheritance type
    # Returns: "inherited", "restricted", "extended", or "different"
    
    set child_emails [dict keys $child_users_dict]
    set parent_emails [dict keys $parent_users_dict]
    
    # If both empty, consider it inherited
    if {[llength $child_emails] == 0 && [llength $parent_emails] == 0} {
        return "inherited"
    }
    
    # If child is empty but parent has users, it's restricted
    if {[llength $child_emails] == 0 && [llength $parent_emails] > 0} {
        return "restricted"
    }
    
    # Count overlaps
    set only_in_child 0
    set only_in_parent 0
    set in_both 0
    
    foreach email $child_emails {
        if {[dict exists $parent_users_dict $email]} {
            incr in_both
        } else {
            incr only_in_child
        }
    }
    
    foreach email $parent_emails {
        if {![dict exists $child_users_dict $email]} {
            incr only_in_parent
        }
    }
    
    # Determine type based on overlap
    if {$only_in_child == 0 && $only_in_parent == 0} {
        # Same users - inherited
        return "inherited"
    } elseif {$only_in_child == 0 && $only_in_parent > 0} {
        # Subset of parent - restricted
        return "restricted"
    } elseif {$only_in_child > 0 && $only_in_parent == 0} {
        # Superset of parent - extended
        return "extended"
    } else {
        # Different sets - different
        return "different"
    }
}

proc build_user_folder_map {all_folders root_users_dict} {
    # Build a map of users to folders they have access to
    # Excludes root folder users unless they appear in subfolders with different permissions
    # Returns: dict with keys=email, values=list of {folder_path role inheritance_type}
    
    set user_map {}
    
    foreach folder $all_folders {
        set folder_path [dict get $folder path]
        set folder_perms [dict get $folder permissions]
        set parent_id [dict get $folder parent_id]
        set is_root [dict get $folder is_root]
        
        # Skip root folder for this analysis
        if {$is_root} {
            continue
        }
        
        set folder_users [extract_users_from_permissions $folder_perms]
        
        foreach {email role} $folder_users {
            # Check if user is in root
            set in_root [dict exists $root_users_dict $email]
            
            if {!$in_root} {
                # User not in root - add to map
                if {![dict exists $user_map $email]} {
                    dict set user_map $email {}
                }
                set folder_list [dict get $user_map $email]
                lappend folder_list [list $folder_path $role "additional"]
                dict set user_map $email $folder_list
            }
        }
    }
    
    return $user_map
}

proc detect_special_folders {all_folders root_users_dict} {
    # Detect folders with non-inherited permissions
    # Returns: list of folder info dicts with inheritance_type
    
    set special_folders {}
    
    foreach folder $all_folders {
        set is_root [dict get $folder is_root]
        
        # Skip root folder
        if {$is_root} {
            continue
        }
        
        set folder_path [dict get $folder path]
        set folder_perms [dict get $folder permissions]
        set folder_users [extract_users_from_permissions $folder_perms]
        
        # Compare with root permissions
        set inheritance_type [compare_permission_sets $folder_users $root_users_dict]
        
        # Only include if not inherited
        if {$inheritance_type ne "inherited"} {
            lappend special_folders [list \
                path $folder_path \
                permissions $folder_perms \
                users_dict $folder_users \
                inheritance_type $inheritance_type]
        }
    }
    
    return $special_folders
}

proc display_recursive_acl {root_path root_permissions all_folders max_depth} {
    # Display ACL information in a user-centric recursive format
    # Shows: 1) Root permissions, 2) Additional users in subfolders, 3) Special folders
    
    set root_users_dict [extract_users_from_permissions $root_permissions]
    set root_emails [lsort [dict keys $root_users_dict]]
    
    # Count unique users and folders
    set all_users_dict $root_users_dict
    set subfolder_count 0
    foreach folder $all_folders {
        set is_root [dict get $folder is_root]
        if {!$is_root} {
            incr subfolder_count
            set folder_perms [dict get $folder permissions]
            set folder_users [extract_users_from_permissions $folder_perms]
            foreach {email role} $folder_users {
                if {![dict exists $all_users_dict $email]} {
                    dict set all_users_dict $email $role
                }
            }
        }
    }
    set total_users [dict size $all_users_dict]
    
    # Display header
    if {$max_depth == 0} {
        puts "\n[string repeat "=" 80]"
        puts "=== ACL for \"$root_path\" ==="
        puts "[string repeat "=" 80]\n"
    } else {
        puts "\n[string repeat "=" 80]"
        puts "=== ACL for \"$root_path\" (recursive scan, max depth: $max_depth) ==="
        puts "[string repeat "=" 80]\n"
    }
    
    # Section 1: Root Folder Permissions
    puts "📊 Root Folder Permissions:"
    if {[llength $root_emails] == 0} {
        puts "   (No non-owner permissions found)\n"
    } else {
        foreach email $root_emails {
            set role [dict get $root_users_dict $email]
            puts [format "   • %-50s (%s)" $email $role]
        }
        puts ""
    }
    
    # Section 2: Additional Users in Subfolders (only if recursive)
    if {$max_depth > 0} {
        set user_folder_map [build_user_folder_map $all_folders $root_users_dict]
        set additional_users [lsort [dict keys $user_folder_map]]
        
        if {[llength $additional_users] > 0} {
            puts "📋 Additional Users in Subfolders:"
            foreach email $additional_users {
                puts "   $email"
                set folder_list [dict get $user_folder_map $email]
                foreach folder_info $folder_list {
                    lassign $folder_info folder_path role inheritance
                    puts [format "      └─ %s (%s)" $folder_path $role]
                }
                puts ""
            }
        }
        
        # Section 3: Special Folders (Non-Inherited Permissions)
        set special_folders [detect_special_folders $all_folders $root_users_dict]
        
        if {[llength $special_folders] > 0} {
            puts "⚠️  Special Folders (Non-Inherited Permissions):"
            foreach folder $special_folders {
                set folder_path [dict get $folder path]
                set folder_users_dict [dict get $folder users_dict]
                set inheritance_type [dict get $folder inheritance_type]
                
                # Display inheritance type
                set type_label "CUSTOM"
                if {$inheritance_type eq "restricted"} {
                    set type_label "RESTRICTED"
                } elseif {$inheritance_type eq "extended"} {
                    set type_label "EXTENDED"
                } elseif {$inheritance_type eq "different"} {
                    set type_label "DIFFERENT"
                }
                
                puts "   📁 $folder_path ($type_label)"
                
                # List users with access
                set folder_emails [lsort [dict keys $folder_users_dict]]
                if {[llength $folder_emails] > 0} {
                    foreach email $folder_emails {
                        set role [dict get $folder_users_dict $email]
                        puts [format "      • %-46s (%s)" $email $role]
                    }
                } else {
                    puts "      (No users with direct permissions)"
                }
                
                # Show who lost access (for restricted folders)
                if {$inheritance_type eq "restricted"} {
                    set lost_access {}
                    foreach {email role} $root_users_dict {
                        if {![dict exists $folder_users_dict $email]} {
                            lappend lost_access $email
                        }
                    }
                    if {[llength $lost_access] > 0} {
                        puts "      ⚠️  Access removed: [join $lost_access ", "]"
                    }
                }
                puts ""
            }
        }
    }
    
    # Summary
    if {$max_depth == 0} {
        puts "[string repeat "-" 80]"
        puts "Summary: $total_users user(s) with access"
        puts "[string repeat "-" 80]\n"
    } else {
        puts "[string repeat "-" 80]"
        puts "Summary: $total_users unique user(s) across 1 root folder + $subfolder_count subfolder(s)"
        puts "[string repeat "-" 80]\n"
    }
}

proc find_onedrive_remotes {} {
    # Find all OneDrive remotes in rclone configuration
    set conf_path [file join ~ .config rclone rclone.conf]
    if {![file exists $conf_path]} {
        return {}
    }
    
    set onedrive_remotes {}
    set config_data [read [open $conf_path r]]
    
    foreach line [split $config_data \n] {
        set line [string trim $line]
        if {[string match "\\\[*\\\]" $line]} {
            set section_name [string range $line 1 end-1]
            # Check if this is a OneDrive type remote
            if {[string match "*onedrive*" [string tolower $section_name]] || 
                [string match "*sharepoint*" [string tolower $section_name]]} {
                lappend onedrive_remotes $section_name
            }
        }
    }
    
    return $onedrive_remotes
}

proc get_access_token {{rclone_remote ""}} {
    set conf_path [file join ~ .config rclone rclone.conf]
    
    if {![file exists $conf_path]} {
        update_status "Error: rclone config not found at $conf_path" red
        update_status "Please configure rclone first: rclone config" red
        return ""
    }
    
    # If no remote specified, find OneDrive remotes and use the first one
    if {$rclone_remote eq ""} {
        set onedrive_remotes [find_onedrive_remotes]
        
        if {[llength $onedrive_remotes] == 0} {
            update_status "Error: No OneDrive remotes found in rclone configuration" red
            update_status "Please configure OneDrive first: rclone config" red
            return ""
        }
        
        if {[llength $onedrive_remotes] == 1} {
            set rclone_remote [lindex $onedrive_remotes 0]
            update_status "No remote name given, using first OneDrive remote: $rclone_remote" blue
        } else {
            update_status "No remote name given, found [llength $onedrive_remotes] OneDrive remotes:" blue
            for {set i 0} {$i < [llength $onedrive_remotes]} {incr i} {
                update_status "  [expr {$i + 1}]. [lindex $onedrive_remotes $i]" blue
            }
            set rclone_remote [lindex $onedrive_remotes 0]
            update_status "Using first OneDrive remote: $rclone_remote" blue
        }
    }
    
    # Read config file
    set config_data [read [open $conf_path r]]
    
    # Parse INI file format properly
    set in_remote_section 0
    set token_json ""
    set remote_type ""
    
    foreach line [split $config_data \n] {
        set line [string trim $line]
        
        # Check for section header
        if {[string match "\\\[*\\\]" $line]} {
            set section_name [string range $line 1 end-1]
            if {$section_name eq $rclone_remote} {
                set in_remote_section 1
                continue
            } else {
                set in_remote_section 0
                continue
            }
        }
        
        # Process lines within the target section
        if {$in_remote_section} {
            if {[string match "type*" $line]} {
                set remote_type [string range $line 5 end]
                set remote_type [string trim $remote_type]
            } elseif {[string match "token*" $line]} {
                set token_json [string range $line 6 end]
                set token_json [string trim $token_json]
            }
        }
    }
    
    if {$token_json eq ""} {
        update_status "Error: No token found for remote '$rclone_remote'" red
        update_status "Please authenticate first: rclone authorize onedrive" red
        return ""
    }
    
    # Parse JSON token
    set access_token ""
    if {[catch {json::json2dict $token_json} token_dict] == 0} {
        # Check if token is expired
        if {[dict exists $token_dict expiry]} {
            set expiry_str [dict get $token_dict expiry]
            if {[catch {
                # Parse ISO format timestamp (e.g., "2025-10-31T01:22:03.598349702+10:00")
                # Use clock scan with the full ISO format including timezone
                set expiry_time [clock scan $expiry_str -format "%Y-%m-%dT%H:%M:%S.%N%z"]
                set current_time [clock seconds]
                
                if {$current_time >= $expiry_time} {
                    update_status "❌ Error: Token has expired!" red
                    update_status "   Token expired on: [clock format $expiry_time -format "%Y-%m-%d %H:%M:%S UTC"]" red
                    update_status "   Current time is: [clock format $current_time -format "%Y-%m-%d %H:%M:%S UTC"]" red
                    update_status "" red
                    update_status "To fix this, please refresh your rclone token:" red
                    update_status "   rclone config reconnect $rclone_remote" red
                    update_status "Or re-authenticate completely:" red
                    update_status "   rclone config" red
                    return ""
                }
            } error_msg]} {
                update_status "Warning: Could not parse token expiry time '$expiry_str': $error_msg" orange
                # Continue anyway in case the expiry format is different
            }
        }
        
        if {[dict exists $token_dict access_token]} {
            set access_token [dict get $token_dict access_token]
            if {$access_token eq ""} {
                update_status "Error: No access_token in token JSON" red
                update_status "Token may be expired. Please re-authenticate: rclone authorize onedrive" red
            } else {
                update_status "✅ Successfully extracted access token from rclone.conf" green
            }
        } else {
            update_status "Error: No access_token in token JSON" red
            update_status "Token may be expired. Please re-authenticate: rclone authorize onedrive" red
        }
    } else {
        update_status "Error: Could not parse token JSON: $token_dict" red
    }
    
    return $access_token
}

# ============================================================================
# Token Management with Capability Detection
# ============================================================================

proc check_token_capability {token_data} {
    # Check if token has ACL editing permissions based on scope
    # Returns: "full", "read-only", or "unknown"
    
    if {![dict exists $token_data scope]} {
        return "unknown"
    }
    
    set scope [dict get $token_data scope]
    
    # Check for required scopes for ACL editing
    # For OneDrive Personal: Files.ReadWrite.All is sufficient
    # For OneDrive Business: Sites.Manage.All may also be needed
    set has_write [expr {[string first "Files.ReadWrite.All" $scope] >= 0 || [string first "Files.ReadWrite" $scope] >= 0}]
    set has_manage [expr {[string first "Sites.Manage.All" $scope] >= 0}]
    
    # If we have Files.ReadWrite.All, that's sufficient for ACL editing on OneDrive Personal
    # Sites.Manage.All is nice to have but Microsoft often doesn't grant it to personal accounts
    if {$has_write} {
        return "full"
    }
    
    if {[string first "Files.Read" $scope] >= 0} {
        return "read-only"
    }
    
    return "unknown"
}

proc is_token_expired {token_data} {
    # Check if token is expired based on expires_at field
    # Returns: 1 if expired, 0 if valid, -1 if no expires_at field
    
    if {![dict exists $token_data expires_at]} {
        debug_log "No expires_at field in token, cannot determine expiration"
        return -1
    }
    
    set expires_at [dict get $token_data expires_at]
    debug_log "Token expires_at: $expires_at"
    
    # Parse ISO 8601 timestamp: 2025-10-22T23:53:05Z
    if {[catch {
        set exp_time [clock scan $expires_at -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
        set now [clock seconds]
        
        debug_log "Current time: [clock format $now -gmt 1 -format "%Y-%m-%dT%H:%M:%SZ"]"
        debug_log "Token expiry: [clock format $exp_time -gmt 1 -format "%Y-%m-%dT%H:%M:%SZ"]"
        
        if {$now >= $exp_time} {
            debug_log "Token is EXPIRED"
            set result 1
        } else {
            set time_left [expr {$exp_time - $now}]
            debug_log "Token is valid, expires in $time_left seconds"
            set result 0
        }
    } error]} {
        debug_log "Error parsing expires_at: $error"
        return -1
    }
    
    return $result
}

proc refresh_access_token {token_data} {
    # Refresh access token using refresh_token
    # Returns: new token_data dict on success, empty dict on failure
    
    global oauth
    
    if {![dict exists $token_data refresh_token]} {
        debug_log "No refresh_token available in token data"
        return {}
    }
    
    set refresh_token [dict get $token_data refresh_token]
    debug_log "Attempting to refresh access token..."
    
    set headers [list Content-Type application/x-www-form-urlencoded]
    set form [::http::formatQuery \
        grant_type    refresh_token \
        refresh_token $refresh_token \
        client_id     $oauth(client_id) \
        client_secret $oauth(client_secret) \
        scope         $oauth(scope)]
    
    # Use result variable pattern (avoid return inside catch)
    set result {}
    set error_msg ""
    set has_error 0
    
    if {[catch {
        set tok [::http::geturl $oauth(token_url) -method POST -headers $headers -query $form -timeout 30000]
        set status [::http::status $tok]
        set ncode [::http::ncode $tok]
        set data [::http::data $tok]
        
        debug_log "Token refresh HTTP status: $status"
        debug_log "Token refresh HTTP code: $ncode"
        
        ::http::cleanup $tok
        
        if {$status ne "ok"} {
            set error_msg "Token refresh failed: HTTP request status is $status"
            error $error_msg
        }
        
        if {$ncode != 200} {
            debug_log "Token refresh failed response: $data"
            set error_msg "Token refresh failed: HTTP $ncode - $data"
            error $error_msg
        }
        
        # Parse JSON response
        debug_log "Parsing token refresh JSON response..."
        set new_token_dict [json::json2dict $data]
        debug_log "New token dict keys: [dict keys $new_token_dict]"
        
        # Check if access_token exists
        if {[dict exists $new_token_dict access_token]} {
            debug_log "✓ Token refresh successful, received new access_token"
            
            # Save the new token to token.json
            save_token_json $new_token_dict
            
            set result $new_token_dict
        } else {
            debug_log "ERROR: No access_token in refresh response!"
            set error_msg "No access_token in token refresh response"
            error $error_msg
        }
    } error] != 0} {
        debug_log "Token refresh error caught: $error"
        set error_msg "Token refresh error: $error"
        set has_error 1
    }
    
    # Return result or empty dict on error (outside catch)
    if {$has_error} {
        debug_log "Token refresh failed: $error_msg"
        return {}
    }
    return $result
}

proc get_access_token_with_capability {rclone_remote {require_capability ""}} {
    # Get access token and determine capability level with expiration checking
    # Returns: {access_token capability_level expiration_info}
    # capability_level: "full", "read-only", or "unknown"
    # expiration_info: ISO timestamp or "unknown" or "expired"
    # require_capability: if set to "full", only return full tokens (fail if only read-only available)
    
    # Try local token.json first
    set token_file "./token.json"
    if {[file exists $token_file]} {
        set parse_error ""
        set token_data {}
        
        # Try to read and parse token.json
        if {[catch {
            set fh [open $token_file r]
            set token_json [read $fh]
            close $fh
            
            debug_log "Read token.json, length: [string length $token_json]"
            
            set token_data [json::json2dict $token_json]
            
            debug_log "Successfully parsed JSON, keys: [dict keys $token_data]"
        } parse_error] == 0} {
            # Successfully parsed, now check expiration
            if {[dict exists $token_data access_token]} {
                set expiration_status [is_token_expired $token_data]
                
                if {$expiration_status == 0} {
                    # Token is valid and not expired
                    set capability [check_token_capability $token_data]
                    set access_token [dict get $token_data access_token]
                    
                    if {[dict exists $token_data expires_at]} {
                        set expires_at [dict get $token_data expires_at]
                    } else {
                        set expires_at "unknown"
                    }
                    
                    debug_log "Token capability: $capability, expires: $expires_at"
                    debug_log "Using valid token.json with capability: $capability"
                    
                    return [list $access_token $capability $expires_at]
                    
                } elseif {$expiration_status == 1} {
                    # Token is expired - try to refresh
                    debug_log "Token in token.json is EXPIRED"
                    
                    if {[dict exists $token_data refresh_token]} {
                        debug_log "Attempting automatic token refresh..."
                        update_status "Token expired, refreshing..." blue
                        
                        set new_token_data [refresh_access_token $token_data]
                        
                        if {[dict size $new_token_data] > 0} {
                            # Refresh successful!
                            set capability [check_token_capability $new_token_data]
                            set access_token [dict get $new_token_data access_token]
                            
                            if {[dict exists $new_token_data expires_at]} {
                                set expires_at [dict get $new_token_data expires_at]
                            } else {
                                set expires_at "unknown"
                            }
                            
                            debug_log "✓ Token refresh successful! New capability: $capability"
                            update_status "✓ Token refreshed successfully (capability: $capability)" green
                            
                            return [list $access_token $capability $expires_at]
                        } else {
                            # Refresh failed
                            debug_log "Token refresh failed, falling back to rclone.conf"
                            update_status "Token refresh failed, falling back to rclone token..." orange
                        }
                    } else {
                        debug_log "No refresh_token available, falling back to rclone.conf"
                        update_status "Token expired (no refresh token), falling back to rclone token..." orange
                    }
                } else {
                    # Cannot determine expiration (-1)
                    debug_log "Cannot determine token expiration, treating as potentially valid"
                    set capability [check_token_capability $token_data]
                    set access_token [dict get $token_data access_token]
                    
                    debug_log "Using token.json with capability: $capability (expiration unknown)"
                    
                    return [list $access_token $capability "unknown"]
                }
            } else {
                debug_log "ERROR: No access_token in parsed JSON"
            }
        } else {
            debug_log "Error reading token.json: $parse_error, falling back to rclone.conf"
        }
    } else {
        debug_log "token.json not found, using rclone.conf"
    }
    
    # Fallback to rclone.conf (assume read-only)
    if {$require_capability eq "full"} {
        debug_log "Full capability required but only rclone token available"
        update_status "❌ Operation requires full permissions. Please re-authenticate." red
        return [list "" "insufficient" "n/a"]
    }
    
    set access_token [get_access_token $rclone_remote]
    if {$access_token ne ""} {
        debug_log "Using rclone.conf token (read-only mode)"
        update_status "Using rclone.conf token (read-only)" blue
        return [list $access_token "read-only" "unknown"]
    }
    
    return [list "" "unknown" "unknown"]
}

proc save_token_json {token_dict} {
    # Save OAuth token to token.json with proper format using json::write
    # Ensures scope is preserved for capability detection
    
    debug_log "save_token_json called with dict keys: [dict keys $token_dict]"
    
    if {![dict exists $token_dict access_token]} {
        debug_log "ERROR: No access_token in token response!"
        debug_log "Token dict contents: $token_dict"
        return -code error "No access_token in token response"
    }
    
    # Calculate expiry timestamp
    set now [clock seconds]
    if {[dict exists $token_dict expires_in]} {
        set delta [dict get $token_dict expires_in]
        set exp [expr {$now + $delta}]
        set expires_at [clock format $exp -gmt 1 -format "%Y-%m-%dT%H:%M:%SZ"]
    } else {
        # Default to 1 hour if not specified
        set exp [expr {$now + 3600}]
        set expires_at [clock format $exp -gmt 1 -format "%Y-%m-%dT%H:%M:%SZ"]
    }
    
    # Build JSON using json::write for proper quoting
    # json::write object takes alternating key/value pairs
    set json_parts [list \
        access_token [json::write string [dict get $token_dict access_token]] \
        token_type [json::write string [dict get $token_dict token_type]] \
        expires_at [json::write string $expires_at]]
    
    # Add optional fields
    if {[dict exists $token_dict scope]} {
        lappend json_parts scope [json::write string [dict get $token_dict scope]]
    }
    if {[dict exists $token_dict expires_in]} {
        lappend json_parts expires_in [json::write string [dict get $token_dict expires_in]]
    }
    if {[dict exists $token_dict refresh_token]} {
        lappend json_parts refresh_token [json::write string [dict get $token_dict refresh_token]]
    }
    
    # Add drive information
    lappend json_parts drive_id [json::write string "5D1B2B3BE100F93B"]
    lappend json_parts drive_type [json::write string "personal"]
    
    # Generate JSON object
    set json_output [json::write object {*}$json_parts]
    
    # Write to file with restricted permissions
    set fh [open "token.json" w 0600]
    puts $fh $json_output
    close $fh
    
    if {[dict exists $token_dict scope]} {
        debug_log "Token saved to token.json with scopes: [dict get $token_dict scope]"
    }
    return 1
}

# ============================================================================
# OAuth Flow Implementation
# ============================================================================

proc oauth_start_local_server {} {
    # Start local HTTP server to capture OAuth callback
    global serverSock
    
    # Close any existing server socket first
    if {$serverSock ne ""} {
        catch {close $serverSock}
        set serverSock ""
    }
    
    if {[catch {
        set serverSock [socket -server oauth_accept 53682]
        debug_log "OAuth callback server started on port 53682"
    } error]} {
        set errorMsg "Failed to start OAuth server on port 53682: $error"
        if {[string match "*address already in use*" $error] || [string match "*Address already in use*" $error]} {
            append errorMsg "\n\nPort 53682 is already in use. Please:"
            append errorMsg "\n1. Check if another instance of this program is running"
            append errorMsg "\n2. Wait a moment and try again"
            append errorMsg "\n3. Or run: lsof -i :53682 (to see what's using the port)"
        }
        update_status "Error starting OAuth server: $error" red
        debug_log $errorMsg
        return ""
    }
    
    return $serverSock
}

proc oauth_accept {chan addr port} {
    # Handle OAuth callback from browser
    global oauth serverSock
    
    debug_log "OAuth callback received from $addr:$port"
    
    # Configure channel for HTTP
    fconfigure $chan -blocking 0 -buffering line -translation {auto crlf}
    
    # Set up fileevent to read HTTP request asynchronously
    fileevent $chan readable [list oauth_handle_request $chan]
}

proc oauth_handle_request {chan} {
    # Handle HTTP request from OAuth callback
    global oauth serverSock
    
    set should_return 0
    if {[catch {
        # Read the HTTP request line
        if {[gets $chan line] < 0} {
            if {[eof $chan]} {
                close $chan
            }
            set should_return 1
        }
        
        debug_log "OAuth callback request: $line"
        
        # Extract authorization code from request
        set code ""
        if {[regexp {GET\s+/\?code=([^&\s]+)} $line -> code]} {
            set oauth(auth_code) $code
            debug_log "Received authorization code: [string range $code 0 20]..."
            
            # Read remaining headers (we don't need them but must consume them)
            while {[gets $chan header] >= 0} {
                if {$header eq ""} {
                    break
                }
            }
            
            # Send success response
            set body "<html><head><title>Authentication Successful</title></head><body style=\"font-family:Arial,sans-serif;text-align:center;padding:50px;\"><h1 style=\"color:green;\">✓ Authentication Successful</h1><p>You can close this window and return to the application.</p></body></html>"
            
            puts $chan "HTTP/1.1 200 OK"
            puts $chan "Content-Type: text/html; charset=utf-8"
            puts $chan "Content-Length: [string length $body]"
            puts $chan "Connection: close"
            puts $chan ""
            puts $chan $body
            flush $chan
            
            # Schedule channel close after giving time to send
            after 100 [list catch [list close $chan]]
            
            # Stop listening after successful callback
            if {$serverSock ne ""} {
                debug_log "Closing OAuth server socket after successful callback"
                after 200 [list catch [list close $serverSock]]
                set serverSock ""
            }
        } else {
            # Read remaining headers
            while {[gets $chan header] >= 0} {
                if {$header eq ""} {
                    break
                }
            }
            
            # Send error response
            set body "<html><head><title>Authentication Error</title></head><body style=\"font-family:Arial,sans-serif;text-align:center;padding:50px;\"><h1 style=\"color:red;\">✗ Authentication Error</h1><p>No authorization code received.</p></body></html>"
            
            puts $chan "HTTP/1.1 400 Bad Request"
            puts $chan "Content-Type: text/html; charset=utf-8"
            puts $chan "Content-Length: [string length $body]"
            puts $chan "Connection: close"
            puts $chan ""
            puts $chan $body
            flush $chan
            
            after 100 [list catch [list close $chan]]
        }
    } error]} {
        debug_log "Error handling OAuth callback: $error"
        catch {close $chan}
    }
    
    if {$should_return} {
        return
    }
}

proc oauth_build_auth_url {} {
    # Build Microsoft authorization URL
    global oauth
    
    set query [::http::formatQuery \
        client_id     $oauth(client_id) \
        response_type code \
        redirect_uri  $oauth(redirect_uri) \
        scope         $oauth(scope) \
        response_mode query \
        prompt        select_account]
    
    return "$oauth(auth_url)?$query"
}

proc oauth_exchange_token {code} {
    # Exchange authorization code for access token
    global oauth
    
    set headers [list Content-Type application/x-www-form-urlencoded]
    set form [::http::formatQuery \
        grant_type    authorization_code \
        code          $code \
        client_id     $oauth(client_id) \
        client_secret $oauth(client_secret) \
        redirect_uri  $oauth(redirect_uri) \
        scope         $oauth(scope)]
    
    debug_log "Exchanging authorization code for access token..."
    debug_log "Token URL: $oauth(token_url)"
    
    # Use a result variable instead of returning from inside catch
    set result ""
    set error_msg ""
    set has_error 0
    
    if {[catch {
        set tok [::http::geturl $oauth(token_url) -method POST -headers $headers -query $form -timeout 30000]
        set status [::http::status $tok]
        set ncode [::http::ncode $tok]
        set data [::http::data $tok]
        set response_headers [::http::meta $tok]
        
        debug_log "Token exchange HTTP status: $status"
        debug_log "Token exchange HTTP code: $ncode"
        debug_log "Token exchange response data length: [string length $data]"
        
        ::http::cleanup $tok
        
        if {$status ne "ok"} {
            set error_msg "Token exchange failed: HTTP request status is $status"
            error $error_msg
        }
        
        if {$ncode != 200} {
            debug_log "Token exchange failed response: $data"
            set error_msg "Token exchange failed: HTTP $ncode - $data"
            error $error_msg
        }
        
        # Parse JSON response
        debug_log "Parsing token JSON response..."
        set result [json::json2dict $data]
        debug_log "Token dict keys: [dict keys $result]"
        
        # Check if access_token exists
        if {[dict exists $result access_token]} {
            debug_log "✓ Token exchange successful, received access_token"
        } else {
            debug_log "ERROR: No access_token in parsed response!"
            set error_msg "No access_token in token response"
            error $error_msg
        }
    } error] != 0} {
        debug_log "Token exchange error caught: $error"
        set error_msg "Token exchange error: $error"
        set has_error 1
    }
    
    # Return the result or error (outside catch)
    if {$has_error} {
        return -code error $error_msg
    }
    return $result
}

proc acquire_elevated_token {} {
    # Show modal dialog with authentication options
    # User chooses: browser auth OR reload token file
    global oauth gui_mode
    
    update_status "Elevated permissions required - please choose authentication method..." blue
    
    # Show modal dialog with two action buttons
    # Dialog handles everything: OAuth server, browser launch, token reload, etc.
    set success [show_oauth_modal_dialog]
    
    if {$success} {
        update_status "✅ Authentication successful!" green
    } else {
        update_status "Authentication cancelled or failed" orange
        cleanup_oauth_server
    }
    
    return $success
}

# ============================================================================
# Modal OAuth Dialog with Token Reload Support
# ============================================================================

proc cleanup_oauth_server {} {
    # Clean up OAuth server socket without resetting auth_code
    # Preserves the OAuth result if already set
    global serverSock
    
    if {[info exists serverSock] && $serverSock ne ""} {
        catch {close $serverSock}
        set serverSock ""
        debug_log "OAuth server socket closed"
    }
}

proc oauth_modal_start_browser_auth {modal_window status_label browser_btn reload_btn} {
    # Start browser authentication when user clicks the button
    debug_log "oauth_modal_start_browser_auth called with args: modal=$modal_window, status=$status_label, browser_btn=$browser_btn, reload_btn=$reload_btn"
    
    global oauth oauth_modal_result
    if {[info exists oauth_modal_result]} {
        debug_log "oauth_modal_result exists, current value: $oauth_modal_result"
    } else {
        debug_log "oauth_modal_result DOES NOT EXIST"
    }
    
    if {[catch {
        set oauth_modal_result 0  # Default to failure
        debug_log "Successfully set oauth_modal_result to 0"
    } err]} {
        debug_log "ERROR setting oauth_modal_result: $err"
        debug_log "Error info: $::errorInfo"
    }
    
    # Disable browser button (can't start twice)
    $browser_btn configure -state disabled
    $status_label configure -text "Starting OAuth server..." -foreground blue
    update
    
    # Start local server
    if {[oauth_start_local_server] eq ""} {
        $status_label configure -text "Failed to start OAuth server" -foreground red
        $browser_btn configure -state normal
        return
    }
    
    # Build auth URL
    set auth_url [oauth_build_auth_url]
    
    $status_label configure -text "Opening browser for authentication..." -foreground blue
    update
    
    # Open browser (platform-specific)
    if {[catch {
        if {$::tcl_platform(platform) eq "windows"} {
            exec cmd /c start $auth_url &
        } elseif {$::tcl_platform(os) eq "Darwin"} {
            exec open $auth_url &
        } else {
            exec xdg-open $auth_url &
        }
    } error]} {
        $status_label configure -text "Error opening browser: $error" -foreground red
        cleanup_oauth_server
        $browser_btn configure -state normal
        return
    }
    
    $status_label configure -text "Waiting for authentication in browser..." -foreground blue
    update
    
    # Start non-blocking completion checker
    set start_time [clock milliseconds]
    after 100 [list oauth_modal_check_completion $modal_window $status_label $start_time]
}

proc oauth_modal_check_completion {modal_window status_label start_time} {
    # Non-blocking periodic check of OAuth completion status
    # Called via 'after' to avoid blocking the event loop
    global oauth oauth_modal_result
    
    # Check if window still exists (user might have closed it)
    if {![winfo exists $modal_window]} {
        debug_log "Modal window destroyed during OAuth wait"
        cleanup_oauth_server
        set oauth(auth_code) "CANCELLED"
        return
    }
    
    # Check OAuth status
    if {$oauth(auth_code) ne ""} {
        if {$oauth(auth_code) eq "CANCELLED"} {
            # User cancelled
            debug_log "OAuth flow cancelled"
            cleanup_oauth_server
            set oauth_modal_result 0
            destroy $modal_window
            return
        } else {
            # Got auth code - proceed to token exchange
            $status_label configure -text "Exchanging authorization code for token..." -foreground blue
            update
            
            if {[catch {
                set token_dict [oauth_exchange_token $oauth(auth_code)]
                save_token_json $token_dict
                set oauth(auth_code) ""
                
                # Update token capability
                global token_capability remote_entry
                set token_result [get_access_token_with_capability [$remote_entry get]]
                set token_capability [lindex $token_result 1]
                # Ignore expires_at (3rd element) here
                
                # Success - close dialog immediately (no confirmation needed)
                set oauth_modal_result 1
                # Disable WM_DELETE_WINDOW before destroying to avoid triggering CANCELLED
                wm protocol $modal_window WM_DELETE_WINDOW {}
                destroy $modal_window
            } error]} {
                $status_label configure -text "Token exchange failed: $error" -foreground red
                set oauth(auth_code) ""
                cleanup_oauth_server
                after 2500 [list destroy $modal_window]
                set oauth_modal_result 0
            }
            return
        }
    }
    
    # Check timeout (120 seconds)
    set elapsed [expr {[clock milliseconds] - $start_time}]
    if {$elapsed > 120000} {
        $status_label configure -text "Authentication timeout - please try again or reload token file" -foreground red
        cleanup_oauth_server
        # Don't close on timeout - let user try reload or close manually
        return
    }
    
    # Update status with elapsed time
    set seconds [expr {$elapsed / 1000}]
    $status_label configure -text "Waiting for browser authentication... ($seconds/120 seconds)" -foreground blue
    
    # Schedule next check
    after 100 [list oauth_modal_check_completion $modal_window $status_label $start_time]
}

proc oauth_modal_reload_token {modal_window status_label reload_btn} {
    # Handle token reload from file with validation
    debug_log "oauth_modal_reload_token called with args: modal=$modal_window, status=$status_label, reload_btn=$reload_btn"
    
    global oauth remote_entry token_capability oauth_modal_result
    if {[info exists oauth_modal_result]} {
        debug_log "oauth_modal_result exists, current value: $oauth_modal_result"
    } else {
        debug_log "oauth_modal_result DOES NOT EXIST"
    }
    
    if {[catch {
        set oauth_modal_result 0  # Default to failure
        debug_log "Successfully set oauth_modal_result to 0"
    } err]} {
        debug_log "ERROR setting oauth_modal_result: $err"
        debug_log "Error info: $::errorInfo"
    }
    
    # Disable button during check
    $reload_btn configure -state disabled
    $status_label configure -text "Checking token.json file..." -foreground blue
    update
    
    # Check for race condition - auth already completing
    if {[info exists oauth(auth_code)] && $oauth(auth_code) ne "" && $oauth(auth_code) ne "CANCELLED"} {
        $status_label configure -text "Browser authentication already completing..." -foreground orange
        $reload_btn configure -state normal
        return
    }
    
    # Try to load token
    if {![file exists "./token.json"]} {
        $status_label configure -text "Error: token.json file not found in current directory" -foreground red
        $reload_btn configure -state normal
        return
    }
    
    # Load and validate token
    if {[catch {
        set token_result [get_access_token_with_capability [$remote_entry get]]
        set access_token [lindex $token_result 0]
        set capability [lindex $token_result 1]
        # expires_at is 3rd element but not needed here
        
        if {$access_token eq ""} {
            error "Invalid or expired token"
        }
        
        if {$capability ne "full"} {
            error "Token has insufficient permissions (scope: $capability)\n\nToken must have Files.ReadWrite.All and Sites.Manage.All scopes"
        }
        
        # Success - valid token with full capability
        set token_capability $capability
        
        # Cleanup OAuth server and signal success
        cleanup_oauth_server
        set oauth(auth_code) "CANCELLED"  ;# Stop any pending OAuth wait
        
        # Close dialog immediately (no confirmation needed)
        set oauth_modal_result 1
        # Disable WM_DELETE_WINDOW before destroying to avoid triggering CANCELLED
        wm protocol $modal_window WM_DELETE_WINDOW {}
        destroy $modal_window
        
    } error]} {
        # Failed to load valid token
        $status_label configure -text "Error: $error" -foreground red
        $reload_btn configure -state normal
    }
}

proc show_oauth_modal_dialog {} {
    # Display modal dialog with two authentication options
    # Returns: 1 if authentication succeeded (OAuth or reload), 0 otherwise
    debug_log "show_oauth_modal_dialog called"
    
    global oauth oauth_modal_result
    if {[info exists oauth_modal_result]} {
        debug_log "oauth_modal_result exists, current value: $oauth_modal_result"
    } else {
        debug_log "oauth_modal_result DOES NOT EXIST"
    }
    
    # Reset oauth state and result
    set oauth(auth_code) ""
    
    if {[catch {
        set oauth_modal_result 0
        debug_log "Successfully set oauth_modal_result to 0 in show_oauth_modal_dialog"
    } err]} {
        debug_log "ERROR setting oauth_modal_result in show_oauth_modal_dialog: $err"
        debug_log "Error info: $::errorInfo"
    }
    
    # Create modal toplevel
    set modal [toplevel .oauth_modal]
    wm title $modal "Elevated Permissions Required"
    wm transient $modal .
    wm protocol $modal WM_DELETE_WINDOW {
        # User closed window - cancel OAuth
        debug_log "WM_DELETE_WINDOW triggered"
        global oauth oauth_modal_result
        debug_log "In WM_DELETE_WINDOW: oauth_modal_result exists? [info exists oauth_modal_result]"
        
        if {[catch {
            set oauth(auth_code) "CANCELLED"
            debug_log "Set oauth(auth_code) to CANCELLED"
            set oauth_modal_result 0
            debug_log "Set oauth_modal_result to 0"
        } err]} {
            debug_log "ERROR in WM_DELETE_WINDOW: $err"
            debug_log "Error info: $::errorInfo"
        }
    }
    
    # Make it modal
    grab set $modal
    
    # Raise to top
    raise $modal
    focus $modal
    
    # Main frame with padding
    set main_frame [ttk::frame $modal.main -padding 20]
    pack $main_frame -fill both -expand yes
    
    # Title
    ttk::label $main_frame.title -text "This operation requires elevated OneDrive permissions" \
        -font {TkDefaultFont 11 bold} -wraplength 510
    pack $main_frame.title -pady {0 20}
    
    # Instructions
    ttk::label $main_frame.instructions \
        -text "Please choose an authentication method:" \
        -justify left
    pack $main_frame.instructions -anchor w -pady {0 15}
    
    # Button frame for the two main action buttons
    set action_frame [ttk::frame $main_frame.actions]
    pack $action_frame -fill x -pady {0 15}
    
    # Browser authentication button
    set browser_btn [ttk::button $action_frame.browser \
        -text "Authenticate with Browser" \
        -width 30]
    pack $browser_btn -pady 5 -anchor center
    
    # Reload token button
    set reload_btn [ttk::button $action_frame.reload \
        -text "Reload Token File" \
        -width 30]
    pack $reload_btn -pady 5 -anchor center
    
    # Status label (shows progress after user clicks a button)
    set status_label [ttk::label $main_frame.status \
        -text "" \
        -foreground blue -justify center]
    pack $status_label -pady {10 10}
    
    # Configure button commands after creating status_label
    $browser_btn configure -command [list oauth_modal_start_browser_auth $modal $status_label $browser_btn $reload_btn]
    $reload_btn configure -command [list oauth_modal_reload_token $modal $status_label $reload_btn]
    
    # Wait for dialog to close (modal loop)
    tkwait window $modal
    
    # Release grab
    catch {grab release $modal}
    
    # Return result from global variable
    return $oauth_modal_result
}

proc make_http_request {url headers {method GET} {body ""}} {
    # Enhanced HTTP request supporting GET, POST, DELETE with better 401 handling
    set token [dict get $headers Authorization]
    
    if {[catch {
        set opts [list -headers [list Authorization $token] -timeout 30000 -method $method]
        
        # Add body for POST requests
        if {$method eq "POST" && $body ne ""} {
            lappend opts -query $body
        }
        
        set response [http::geturl $url {*}$opts]
        set status [http::ncode $response]
        set data [http::data $response]
        http::cleanup $response
        
        if {$status ne "200" && $status ne "201" && $status ne "204"} {
            # Enhanced error message for 401 (authentication) errors
            if {$status eq "401"} {
                # Try to parse error response for better message
                if {[catch {json::json2dict $data} error_dict] == 0} {
                    if {[dict exists $error_dict error]} {
                        set error_info [dict get $error_dict error]
                        if {[dict exists $error_info code]} {
                            set error_code [dict get $error_info code]
                            if {$error_code eq "InvalidAuthenticationToken" || [string match "*expired*" [string tolower $error_code]]} {
                                puts "ERROR: HTTP 401 - Token expired or invalid"
                                puts "ERROR: $data"
                                set result [list $status "TOKEN_EXPIRED: $data"]
                                return $result
                            }
                        }
                    }
                }
                puts "ERROR: HTTP 401 - Authentication failed - URL: $url"
            } else {
                puts "ERROR: HTTP $status - URL: $url"
            }
            puts "ERROR: Response data: $data"
        }
        
        set result [list $status $data]
    } error]} {
        puts "ERROR: HTTP request failed - $error"
        puts "ERROR: URL was: $url"
        set result [list "error" $error]
    }
    return $result
}

# ============================================================================
# Microsoft Graph API Operations for ACL Editing
# ============================================================================

proc invite_user_to_item {item_id email role access_token} {
    # Invite a user to an item with specified role
    # role: "read" or "write"
    # Returns: {status message}
    
    set url "https://graph.microsoft.com/v1.0/me/drive/items/$item_id/invite"
    set headers [list Authorization "Bearer $access_token" Content-Type "application/json"]
    
    # Build request body
    set body_dict [dict create \
        requireSignIn true \
        roles [list $role] \
        recipients [list [dict create email $email]] \
        message "You have been granted $role access to this item."]
    
    set body_json [json::dict2json $body_dict]
    
    set result [make_http_request $url $headers POST $body_json]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status eq "200" || $status eq "201"} {
        return [list "ok" "Successfully invited $email with $role permission"]
    } elseif {$status eq "403"} {
        return [list "error" "Insufficient permissions to invite users"]
    } elseif {$status eq "404"} {
        return [list "error" "Item not found"]
    } else {
        return [list "error" "Failed to invite user: HTTP $status"]
    }
}

proc remove_permission {item_id permission_id access_token} {
    # Remove a specific permission from an item
    # Returns: {status message}
    
    set url "https://graph.microsoft.com/v1.0/me/drive/items/$item_id/permissions/$permission_id"
    set headers [list Authorization "Bearer $access_token"]
    
    set result [make_http_request $url $headers DELETE]
    set status [lindex $result 0]
    
    if {$status eq "204"} {
        return [list "ok" "Permission removed successfully"]
    } elseif {$status eq "403"} {
        return [list "error" "Insufficient permissions to remove this permission"]
    } elseif {$status eq "404"} {
        return [list "error" "Permission not found (may already be removed)"]
    } elseif {$status eq "401"} {
        return [list "error" "Token expired or invalid"]
    } else {
        return [list "error" "Failed to remove permission: HTTP $status"]
    }
}

proc strip_explicit_permissions {item_id access_token} {
    # Remove all explicit (non-inherited, non-owner) permissions
    # Returns: {status count_removed message}
    
    # Get all permissions
    set permissions_url "https://graph.microsoft.com/v1.0/me/drive/items/$item_id/permissions"
    set headers [list Authorization "Bearer $access_token"]
    set result [make_http_request $permissions_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status ne "200"} {
        return [list "error" 0 "Failed to fetch permissions: HTTP $status"]
    }
    
    set permissions_data [json::json2dict $data]
    set permissions [dict get $permissions_data value]
    
    set removed_count 0
    set failed_count 0
    
    foreach perm $permissions {
        # Skip owner permissions
        if {[is_owner_permission $perm]} {
            continue
        }
        
        # Skip inherited permissions
        if {[is_inherited_permission $perm]} {
            continue
        }
        
        # Remove this explicit permission
        set permission_id [dict get $perm id]
        set remove_result [remove_permission $item_id $permission_id $access_token]
        set remove_status [lindex $remove_result 0]
        
        if {$remove_status eq "ok"} {
            incr removed_count
        } else {
            incr failed_count
        }
    }
    
    if {$failed_count > 0} {
        return [list "warning" $removed_count "Removed $removed_count permission(s), $failed_count failed"]
    } else {
        return [list "ok" $removed_count "Removed $removed_count explicit permission(s)"]
    }
}

# ============================================================================
# Edit Mode Button Handlers
# ============================================================================

proc ensure_edit_capability {} {
    # Check if we have edit capability, trigger OAuth flow if needed
    # Returns: 1 if we have edit capability, 0 if user cancelled or failed
    global token_capability remote_entry
    
    # Get current token capability
    set result [get_access_token_with_capability [$remote_entry get]]
    set access_token [lindex $result 0]
    set capability [lindex $result 1]
    # expires_at is 3rd element but not needed here
    set token_capability $capability
    
    if {$capability eq "full"} {
        # Already have edit capability
        return 1
    }
    
    # Need to acquire elevated token - show modal directly
    # Modal provides both options: browser auth OR token file reload
    # User can cancel if they don't want to proceed
    if {[acquire_elevated_token]} {
        return 1
    } else {
        return 0
    }
}

proc on_invite_user_click {} {
    # Show dialog to invite a user
    global current_item_id remote_entry tree
    
    if {$current_item_id eq ""} {
        tk_messageBox -type ok -icon warning -title "No Item Selected" \
            -message "Please fetch ACL for an item first."
        return
    }
    
    # Check if we have edit capability (will prompt for OAuth if needed)
    if {![ensure_edit_capability]} {
        return
    }
    
    # Create dialog window
    set dialog [toplevel .invite_dialog]
    wm title $dialog "Invite User"
    wm transient $dialog .
    
    # Email entry
    ttk::label $dialog.email_label -text "Email address:"
    ttk::entry $dialog.email_entry -width 40
    
    # Role selection
    ttk::label $dialog.role_label -text "Permission level:"
    ttk::frame $dialog.role_frame
    ttk::radiobutton $dialog.role_frame.read -text "Read (view only)" -variable invite_role -value "read"
    ttk::radiobutton $dialog.role_frame.write -text "Write (can edit)" -variable invite_role -value "write"
    set ::invite_role "read"
    
    # Buttons
    ttk::frame $dialog.buttons
    ttk::button $dialog.buttons.ok -text "Invite" -command {set ::invite_dialog_result ok}
    ttk::button $dialog.buttons.cancel -text "Cancel" -command {set ::invite_dialog_result cancel}
    
    # Layout
    pack $dialog.email_label -anchor w -padx 10 -pady {10 0}
    pack $dialog.email_entry -fill x -padx 10 -pady {0 10}
    pack $dialog.role_label -anchor w -padx 10 -pady {10 0}
    pack $dialog.role_frame -anchor w -padx 20 -pady {0 10}
    pack $dialog.role_frame.read -anchor w
    pack $dialog.role_frame.write -anchor w
    pack $dialog.buttons -side bottom -pady 10
    pack $dialog.buttons.ok -side left -padx 5
    pack $dialog.buttons.cancel -side left -padx 5
    
    # Wait for dialog result
    set ::invite_dialog_result ""
    focus $dialog.email_entry
    grab $dialog
    tkwait variable ::invite_dialog_result
    
    if {$::invite_dialog_result eq "ok"} {
        set email [string trim [$dialog.email_entry get]]
        set role $::invite_role
        
        destroy $dialog
        
        if {$email eq ""} {
            tk_messageBox -type ok -icon warning -title "Invalid Input" \
                -message "Please enter an email address."
            return
        }
        
        # Get access token
        set result [get_access_token_with_capability [$remote_entry get]]
        set access_token [lindex $result 0]
        # capability is 2nd element, expires_at is 3rd (not needed here)
        
        if {$access_token eq ""} {
            update_status "Error: No access token available" red
            return
        }
        
        # Invite user
        update_status "Inviting $email..." blue
        set invite_result [invite_user_to_item $current_item_id $email $role $access_token]
        set invite_status [lindex $invite_result 0]
        set invite_message [lindex $invite_result 1]
        
        if {$invite_status eq "ok"} {
            update_status "✅ $invite_message" green
            # Refresh ACL display
            after 1000 {refresh_current_acl}
        } elseif {$invite_status eq "error" && [string match "*401*" $invite_message]} {
            update_status "Token expired - please try again" red
        } else {
            update_status "❌ $invite_message" red
        }
    } else {
        destroy $dialog
    }
}

proc on_remove_selected_click {} {
    # Remove selected permissions from treeview
    global tree current_item_id remote_entry
    
    if {$current_item_id eq ""} {
        tk_messageBox -type ok -icon warning -title "No Item Selected" \
            -message "Please fetch ACL for an item first."
        return
    }
    
    # Get selected items
    set selection [$tree selection]
    
    if {[llength $selection] == 0} {
        tk_messageBox -type ok -icon warning -title "No Selection" \
            -message "Please select one or more permissions to remove."
        return
    }
    
    # Check if we have edit capability (will prompt for OAuth if needed)
    if {![ensure_edit_capability]} {
        return
    }
    
    # Confirm removal
    set count [llength $selection]
    set response [tk_messageBox -type yesno -icon warning -title "Confirm Removal" \
        -message "Remove $count permission(s)?\n\nThis cannot be undone."]
    
    if {$response ne "yes"} {
        return
    }
    
    # Get access token
    set result [get_access_token_with_capability [$remote_entry get]]
    set access_token [lindex $result 0]
    # capability is 2nd element, expires_at is 3rd (not needed here)
    
    if {$access_token eq ""} {
        update_status "Error: No access token available" red
        return
    }
    
    # Remove each selected permission
    set success_count 0
    set fail_count 0
    
    update_status "Removing $count permission(s)..." blue
    
    foreach item $selection {
        set values [$tree item $item -values]
        set permission_id [lindex $values 0]
        
        set remove_result [remove_permission $current_item_id $permission_id $access_token]
        set remove_status [lindex $remove_result 0]
        
        if {$remove_status eq "ok"} {
            incr success_count
        } else {
            incr fail_count
            set error_msg [lindex $remove_result 1]
            if {[string match "*401*" $error_msg]} {
                update_status "Token expired - please try again" red
                return
            }
        }
    }
    
    if {$fail_count == 0} {
        update_status "✅ Removed $success_count permission(s)" green
    } else {
        update_status "⚠️ Removed $success_count, failed $fail_count" orange
    }
    
    # Refresh ACL display
    after 1000 {refresh_current_acl}
}

proc refresh_current_acl {} {
    # Refresh the current ACL display
    global selected_item
    
    if {[dict exists $selected_item path]} {
        set item_path [dict get $selected_item path]
        fetch_acl $item_path
    }
}

proc analyze_permissions {permissions} {
    # Analyze permissions to determine sharing type and get shared user list.
    # Identifies owner by looking for "owner" role instead of requiring user ID.
    # Returns: List of {has_link_sharing has_direct_sharing permission_count shared_users}
    set has_link_sharing 0
    set has_direct_sharing 0
    set shared_users {}
    
    foreach perm $permissions {
        # Skip owner permissions (identified by "owner" role)
        if {[is_owner_permission $perm]} {
            continue
        }
        
        # Check if this is a link permission
        if {[dict exists $perm link]} {
            set link [dict get $perm link]
            if {[dict exists $link type]} {
                set has_link_sharing 1
            }
        }
        
        # Check if this is a direct permission
        if {[dict exists $perm grantedTo user]} {
            set has_direct_sharing 1
            lassign [extract_user_info $perm] user_name email
            if {$email ne "N/A" && [lsearch $shared_users $email] < 0} {
                lappend shared_users $email
            }
        }
        
        # Check grantedToIdentities (OneDrive Business)
        if {[dict exists $perm grantedToIdentities]} {
            set identities [dict get $perm grantedToIdentities]
            foreach identity $identities {
                if {[dict exists $identity user]} {
                    set user [dict get $identity user]
                    set has_direct_sharing 1
                    set email [dict get $user email]
                    if {$email eq ""} {
                        set email [dict get $user displayName]
                    }
                    if {$email ne "" && [lsearch $shared_users $email] < 0} {
                        lappend shared_users $email
                    }
                }
            }
        }
    }
    
    return [list $has_link_sharing $has_direct_sharing [llength $permissions] $shared_users]
}

proc get_item_path {item_id access_token} {
    # Get the full path of an item using its parent chain
    set headers [list Authorization "Bearer $access_token"]
    set path_parts {}
    set current_id $item_id
    set result_path "Unknown"
    
    if {[catch {
        while {$current_id ne ""} {
            set url "https://graph.microsoft.com/v1.0/me/drive/items/$current_id"
            set result [make_http_request $url $headers]
            set status [lindex $result 0]
            set data [lindex $result 1]
            
            if {$status ne "200"} {
                break
            }
            
            set item_data [json::json2dict $data]
            set name [dict get $item_data name]
            set path_parts [linsert $path_parts 0 $name]
            
            if {[dict exists $item_data parentReference]} {
                set parent_ref [dict get $item_data parentReference]
                if {[dict exists $parent_ref path] && [dict get $parent_ref path] eq "/drive/root:"} {
                    break
                }
                if {[dict exists $parent_ref id]} {
                    set current_id [dict get $parent_ref id]
                } else {
                    break
                }
            } else {
                break
            }
        }
        
        # Remove 'root' from path if present
        if {[llength $path_parts] > 0 && [string tolower [lindex $path_parts 0]] eq "root"} {
            set path_parts [lrange $path_parts 1 end]
        }
        
        if {[llength $path_parts] > 0} {
            set result_path [join $path_parts "/"]
        }
    } error] != 0} {
        # Keep result_path as "Unknown"
    }
    
    return $result_path
}

proc get_folder_permissions {folder_id access_token} {
    # Get permissions for a folder
    # Returns list of {status permissions} where status is "ok" or "error"
    set permissions_url [build_graph_api_url "/me/drive/items/$folder_id/permissions"]
    set headers [list Authorization "Bearer $access_token"]
    set result [make_http_request $permissions_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status eq "200"} {
        set permissions_data [json::json2dict $data]
        set permissions [dict get $permissions_data value]
        return [list "ok" $permissions]
    } else {
        return [list "error" {}]
    }
}

proc has_explicit_user_permission {permissions target_user_lower} {
    # Check if any permission explicitly grants access to the target user
    # (non-inherited, non-owner)
    foreach perm $permissions {
        # Skip owner permissions
        if {[is_owner_permission $perm]} {
            continue
        }
        
        # Check if this permission is inherited
        if {[is_inherited_permission $perm]} {
            continue
        }
        
        # Check direct user permissions
        if {[dict exists $perm grantedTo user]} {
            set user [dict get $perm grantedTo user]
            set user_email [string tolower [dict get $user email]]
            if {[string first $target_user_lower $user_email] >= 0} {
                return 1
            }
        }
        
        # Check grantedToIdentities (OneDrive Business)
        if {[dict exists $perm grantedToIdentities]} {
            set identities [dict get $perm grantedToIdentities]
            foreach identity $identities {
                if {[dict exists $identity user]} {
                    set user [dict get $identity user]
                    set user_email [string tolower [dict get $user email]]
                    if {[string first $target_user_lower $user_email] >= 0} {
                        return 1
                    }
                }
            }
        }
    }
    return 0
}

proc add_shared_folder_result {folder_id folder_path access_token has_link has_direct perm_count shared_users target_user_lower shared_folders_var} {
    # Add a shared folder to the results list
    upvar $shared_folders_var shared
    
    # Get folder name
    set folder_info_url [build_graph_api_url "/me/drive/items/$folder_id"]
    set headers [list Authorization "Bearer $access_token"]
    set info_result [make_http_request $folder_info_url $headers]
    set info_status [lindex $info_result 0]
    set info_data [lindex $info_result 1]
    set folder_name "Unknown"
    if {$info_status eq "200"} {
        set folder_data [json::json2dict $info_data]
        set folder_name [dict get $folder_data name]
    }
    
    # Determine symbol and sharing type
    if {$has_link} {
        set symbol "🔗"
        set share_type "Link sharing"
    } else {
        set symbol "👥"
        set share_type "Direct permissions"
    }
    
    # Get the folder ID by path to ensure consistency
    set consistent_folder_id $folder_id
    if {$folder_path ne ""} {
        if {[catch {
            set path_url [get_item_url_from_path $folder_path]
            set path_result [make_http_request $path_url $headers]
            set path_status [lindex $path_result 0]
            set path_data [lindex $path_result 1]
            if {$path_status eq "200"} {
                set path_dict [json::json2dict $path_data]
                set consistent_folder_id [dict get $path_dict id]
            }
        } error]} {
            # Fall back to original folder_id if path lookup fails
            set consistent_folder_id $folder_id
        }
    }
    
    lappend shared [list \
        path $folder_path \
        name $folder_name \
        id $consistent_folder_id \
        symbol $symbol \
        share_type $share_type \
        has_link_sharing $has_link \
        has_direct_sharing $has_direct \
        permission_count $perm_count \
        shared_users $shared_users]
    
    if {$target_user_lower ne ""} {
        puts "   ✅ Found explicit permission: $symbol $folder_path"
    } else {
        puts "   ✅ Found shared: $symbol $folder_path"
    }
}

proc scan_items_recursive {folder_id access_token max_depth current_depth folder_path parent_id checked_folders folders_per_level results {mode "collect_all"} {target_user_lower ""} {item_type "folders"}} {
    # Unified recursive scanner that handles both collection and filtering modes
    # 
    # Parameters:
    #   folder_id           - ID of folder to scan
    #   access_token        - Microsoft Graph API access token
    #   max_depth          - Maximum recursion depth
    #   current_depth      - Current recursion depth
    #   folder_path        - Path string for display
    #   parent_id          - Parent folder ID (used in collect_all mode)
    #   checked_folders    - Variable name for tracking checked folders
    #   folders_per_level  - Variable name for tracking folder counts by level
    #   results            - Variable name for storing results
    #   mode               - "collect_all" (store all permissions) or "filter" (filter by criteria)
    #   target_user_lower  - Email of user to filter by (lowercase, for filter mode)
    #   item_type          - "folders", "files", or "both"
    #
    # Returns: Nothing (results stored in upvar variables)
    
    upvar $checked_folders checked
    upvar $folders_per_level folders
    upvar $results collected
    
    if {$current_depth >= $max_depth || [lsearch $checked $folder_id] >= 0} {
        return
    }
    
    lappend checked $folder_id
    
    # Track folder count per level
    if {![info exists folders($current_depth)]} {
        set folders($current_depth) 0
    }
    incr folders($current_depth)
    
    # Show progress every 10 folders
    set total_checked [llength $checked]
    if {$total_checked % 10 == 0} {
        puts "   📁 Scanned $total_checked folders..."
    }
    
    if {[catch {
        # Get permissions for this folder
        lassign [get_folder_permissions $folder_id $access_token] perm_status permissions
        
        if {$perm_status eq "ok"} {
            # Process based on mode
            if {$mode eq "collect_all"} {
                # Mode 1: Store complete folder information for display
                set is_root [expr {$current_depth == 0}]
                lappend collected [list \
                    path $folder_path \
                    id $folder_id \
                    parent_id $parent_id \
                    permissions $permissions \
                    is_root $is_root \
                    depth $current_depth]
                    
            } elseif {$mode eq "filter"} {
                # Mode 2: Filter and analyze permissions
                set analysis [analyze_permissions $permissions]
                set has_link [lindex $analysis 0]
                set has_direct [lindex $analysis 1]
                set perm_count [lindex $analysis 2]
                set shared_users [lindex $analysis 3]
                
                # Check for explicit user permissions if target_user is specified
                set has_explicit_user_perm 0
                if {$target_user_lower ne ""} {
                    set has_explicit_user_perm [has_explicit_user_permission $permissions $target_user_lower]
                }
                
                # Determine if this folder should be included in results
                set should_include_folder 0
                if {$target_user_lower ne ""} {
                    # When filtering by user, only include if explicit permission found
                    set should_include_folder $has_explicit_user_perm
                } else {
                    # When not filtering by user, include all shared folders
                    set should_include_folder [expr {$has_link || $has_direct}]
                }
                
                if {$should_include_folder} {
                    # Get full path if not already provided
                    if {$folder_path eq ""} {
                        set folder_path [get_item_path $folder_id $access_token]
                    }
                    
                    add_shared_folder_result $folder_id $folder_path $access_token $has_link $has_direct $perm_count $shared_users $target_user_lower collected
                }
                
                # Implement pruning: if explicit user permission found, skip children
                if {$target_user_lower ne "" && $has_explicit_user_perm} {
                    puts "   🚀 Pruning: Found explicit permission, skipping subfolders (inherited)"
                    return
                }
            }
        }
        
        # Get children of this folder and recursively check them
        set headers [list Authorization "Bearer $access_token"]
        set children_url [build_graph_api_url "/me/drive/items/$folder_id/children"]
        set children_result [make_http_request $children_url $headers]
        set children_status [lindex $children_result 0]
        set children_data [lindex $children_result 1]
        
        if {$children_status eq "200"} {
            set children_dict [json::json2dict $children_data]
            set children [dict get $children_dict value]
            
            foreach child $children {
                set is_folder [dict exists $child folder]
                set is_file [dict exists $child file]
                
                # Determine if we should process this child based on item_type
                set should_process 0
                if {$item_type eq "folders" && $is_folder} {
                    set should_process 1
                } elseif {$item_type eq "files" && $is_file} {
                    set should_process 1
                } elseif {$item_type eq "both"} {
                    set should_process 1
                }
                
                if {$should_process} {
                    set child_id [dict get $child id]
                    set child_name [dict get $child name]
                    set child_path "$folder_path/$child_name"
                    if {$folder_path eq ""} {
                        set child_path $child_name
                    }
                    
                    if {$is_folder} {
                        # Recursively scan this child folder
                        scan_items_recursive $child_id $access_token $max_depth [expr $current_depth + 1] $child_path $folder_id checked folders collected $mode $target_user_lower $item_type
                    } elseif {$is_file && $mode eq "filter" && ($item_type eq "files" || $item_type eq "both")} {
                        # For files in filter mode, check permissions but don't recurse
                        lassign [get_folder_permissions $child_id $access_token] file_perm_status file_permissions
                        
                        if {$file_perm_status eq "ok"} {
                            set file_analysis [analyze_permissions $file_permissions]
                            set file_has_link [lindex $file_analysis 0]
                            set file_has_direct [lindex $file_analysis 1]
                            set file_perm_count [lindex $file_analysis 2]
                            set file_shared_users [lindex $file_analysis 3]
                            
                            if {$target_user_lower ne ""} {
                                set file_has_user [has_explicit_user_permission $file_permissions $target_user_lower]
                                if {$file_has_user} {
                                    add_shared_folder_result $child_id $child_path $access_token $file_has_link $file_has_direct $file_perm_count $file_shared_users $target_user_lower collected
                                }
                            }
                        }
                    }
                }
            }
        }
        
    } error]} {
        # Skip folders we can't access
    }
}

proc cli_get_full_token {remote_name} {
    # Helper function for CLI operations requiring full permissions
    # Returns: {access_token} on success, empty string on failure
    # Handles all error messaging internally
    
    set result [get_access_token_with_capability $remote_name "full"]
    set access_token [lindex $result 0]
    set capability [lindex $result 1]
    
    if {$access_token eq "" || $capability ne "full"} {
        puts "❌ Operation requires full permissions (Files.ReadWrite.All + Sites.Manage.All)"
        puts ""
        puts "This operation failed because:"
        if {$capability eq "insufficient"} {
            puts "  - token.json is expired or missing"
            puts "  - rclone.conf token only has read-only permissions"
        } else {
            puts "  - No valid authentication token available"
        }
        puts ""
        puts "To fix this:"
        puts "  1. Run the script in GUI mode (wish acl-inspector.tcl)"
        puts "  2. Trigger an operation requiring permissions (Invite or Remove)"
        puts "  3. Complete browser authentication"
        puts "  4. Try this command again"
        puts ""
        puts "Alternatively, manually update token.json with a valid full-permission token."
        return ""
    }
    
    puts "✅ Using token with full permissions"
    return $access_token
}

proc cli_get_item_from_path {path access_token} {
    # Helper function to get item ID and dict from path
    # Returns: {item_id item_dict} on success, empty list on failure
    # Handles all error messaging internally
    
    set item_url [get_item_url_from_path $path]
    set headers [list Authorization "Bearer $access_token"]
    set result [make_http_request $item_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status ne "200"} {
        puts "❌ Failed to get item: $status"
        return {}
    }
    
    set item_dict [json::json2dict $data]
    set item_id [dict get $item_dict id]
    
    return [list $item_id $item_dict]
}

proc remove_user_permissions_cli {path user_email max_depth item_type dry_run remote_name} {
    # CLI wrapper for removing user permissions
    puts "🗑️  Removing user permissions"
    puts "User: $user_email"
    puts "Starting path: $path"
    if {$max_depth > 0} {
        puts "Max depth: $max_depth"
        puts "Item type: $item_type"
    } else {
        puts "Mode: Non-recursive (single item only)"
    }
    if {$dry_run} {
        puts "⚠️  DRY RUN MODE - No changes will be made"
    }
    puts ""
    
    # Get access token with full capability requirement
    set access_token [cli_get_full_token $remote_name]
    if {$access_token eq ""} {
        return
    }
    
    set target_user_lower [string tolower $user_email]
    set items_to_remove {}
    
    # Collect items with user permissions
    if {$max_depth == 0} {
        # Non-recursive: just check this single path
        set item_id [get_item_id_from_path $path $access_token]
        if {$item_id eq ""} {
            puts "❌ Failed to get item ID for path: $path"
            return
        }
        
        lassign [get_folder_permissions $item_id $access_token] perm_status permissions
        if {$perm_status eq "ok"} {
            set has_user_perm [has_explicit_user_permission $permissions $target_user_lower]
            if {$has_user_perm} {
                # Find permission ID for this user
                foreach perm $permissions {
                    set user_info [extract_user_info $perm]
                    set perm_user_email [lindex $user_info 1]
                    if {[string tolower $perm_user_email] eq $target_user_lower} {
                        set perm_id [dict get $perm id]
                        lappend items_to_remove [dict create path $path item_id $item_id perm_id $perm_id]
                    }
                }
            }
        }
    } else {
        # Recursive: scan and collect items
        puts "🔍 Scanning for items with user permissions..."
        
        set shared_folders {}
        set checked_folders {}
        set folders_per_level(0) 0
        
        # Get starting item ID
        set item_result [cli_get_item_from_path $path $access_token]
        if {[llength $item_result] == 0} {
            return
        }
        lassign $item_result start_id item_dict
        
        # Recursively find items
        scan_items_recursive $start_id $access_token $max_depth 0 $path "" checked_folders folders_per_level shared_folders "filter" $target_user_lower $item_type
        
        puts "✅ Scan complete. Found [llength $shared_folders] items."
        puts ""
        
        # Extract item IDs and permission IDs from shared_folders
        foreach folder $shared_folders {
            set folder_id [dict get $folder id]
            set folder_path [dict get $folder path]
            
            # Get permissions to find the specific permission ID for this user
            lassign [get_folder_permissions $folder_id $access_token] perm_status permissions
            if {$perm_status eq "ok"} {
                foreach perm $permissions {
                    set user_info [extract_user_info $perm]
                    set perm_user_email [lindex $user_info 1]
                    if {[string tolower $perm_user_email] eq $target_user_lower} {
                        set perm_id [dict get $perm id]
                        lappend items_to_remove [dict create path $folder_path item_id $folder_id perm_id $perm_id]
                    }
                }
            }
        }
    }
    
    if {[llength $items_to_remove] == 0} {
        puts "ℹ️  No items found with permissions for $user_email"
        return
    }
    
    puts "Found [llength $items_to_remove] item(s) with permissions for $user_email:"
    foreach item $items_to_remove {
        set item_path [dict get $item path]
        puts "  - $item_path"
    }
    puts ""
    
    if {$dry_run} {
        puts "⚠️  DRY RUN: Would remove [llength $items_to_remove] permission(s)"
        return
    }
    
    # Confirm before removal
    puts "⚠️  This will remove $user_email's access from [llength $items_to_remove] item(s)."
    puts -nonewline "Continue? \[y/N\]: "
    flush stdout
    set response [gets stdin]
    
    if {$response ne "y" && $response ne "Y"} {
        puts "❌ Cancelled by user"
        return
    }
    
    # Perform removals
    puts ""
    puts "🗑️  Removing permissions..."
    set success_count 0
    set error_count 0
    
    foreach item $items_to_remove {
        set item_path [dict get $item path]
        set item_id [dict get $item item_id]
        set perm_id [dict get $item perm_id]
        
        set remove_result [remove_permission $item_id $perm_id $access_token]
        set remove_status [lindex $remove_result 0]
        
        if {$remove_status eq "ok"} {
            puts "  ✅ $item_path"
            incr success_count
        } else {
            set remove_message [lindex $remove_result 1]
            puts "  ❌ $item_path - $remove_message"
            incr error_count
        }
    }
    
    puts ""
    puts "=== Summary ==="
    puts "✅ Successfully removed: $success_count"
    if {$error_count > 0} {
        puts "❌ Errors: $error_count"
    }
}

proc get_item_id_from_path {path access_token} {
    # Helper function to get item ID from path
    set item_url [get_item_url_from_path $path]
    
    set headers [list Authorization "Bearer $access_token"]
    set result [make_http_request $item_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status eq "200"} {
        set item_dict [json::json2dict $data]
        return [dict get $item_dict id]
    }
    
    return ""
}

proc invite_user_cli {path user_email read_only remote_name} {
    # CLI wrapper for inviting user to a path
    puts "📧 Inviting user to path: $path"
    puts "User: $user_email"
    puts "Access level: [expr {$read_only ? "read-only" : "read/write"}]"
    puts ""
    
    # Get access token with full capability requirement
    set access_token [cli_get_full_token $remote_name]
    if {$access_token eq ""} {
        return
    }
    
    # Get item ID from path
    set item_result [cli_get_item_from_path $path $access_token]
    if {[llength $item_result] == 0} {
        return
    }
    lassign $item_result item_id item_dict
    set item_name [dict get $item_dict name]
    
    puts "📁 Found item: $item_name (ID: $item_id)"
    
    # Invite user
    set role [expr {$read_only ? "read" : "write"}]
    set invite_result [invite_user_to_item $item_id $user_email $role $access_token]
    set invite_status [lindex $invite_result 0]
    set invite_message [lindex $invite_result 1]
    
    if {$invite_status eq "ok"} {
        puts "✅ $invite_message"
        puts ""
        puts "ℹ️  Note: This permission is inherited by all children of this folder"
    } else {
        puts "❌ $invite_message"
    }
}

proc list_user_access {path user_email max_depth item_type remote_name} {
    # List items where user has access
    # Supports both recursive (max_depth > 0) and non-recursive (max_depth = 0) modes
    
    if {$max_depth == 0} {
        # Non-recursive mode: just check this path's ACL for user
        puts "🔍 Checking access for user: $user_email"
        puts "Path: $path"
        puts ""
        
        # Get access token
        set access_token [get_access_token $remote_name]
        if {$access_token eq ""} {
            return
        }
        
        puts "✅ Successfully extracted access token from rclone.conf"
        
        # Get item ID from path
        set item_result [cli_get_item_from_path $path $access_token]
        if {[llength $item_result] == 0} {
            return
        }
        lassign $item_result item_id item_dict
        set item_name [dict get $item_dict name]
        
        # Get permissions
        set headers [list Authorization "Bearer $access_token"]
        set permissions_url [build_graph_api_url "/me/drive/items/$item_id/permissions"]
        set result [make_http_request $permissions_url $headers]
        set status [lindex $result 0]
        set data [lindex $result 1]
        
        if {$status ne "200"} {
            puts "❌ Failed to get permissions: $status"
            return
        }
        
        set permissions_dict [json::json2dict $data]
        set permissions [dict get $permissions_dict value]
        
        # Check for user permission
        set target_user_lower [string tolower $user_email]
        set has_permission [has_explicit_user_permission $permissions $target_user_lower]
        
        if {$has_permission} {
            puts "✅ User $user_email has access to: $path"
            
            # Show permission details
            foreach perm $permissions {
                set user_info [extract_user_info $perm]
                set perm_user_name [lindex $user_info 0]
                set perm_user_email [lindex $user_info 1]
                
                if {[string tolower $perm_user_email] eq $target_user_lower} {
                    set roles [dict get $perm roles]
                    puts "   └─ Roles: [join $roles ", "]"
                }
            }
        } else {
            puts "ℹ️  User $user_email does not have explicit access to: $path"
        }
        
    } else {
        # Recursive mode: use existing scan logic
        scan_shared_folders_user_impl $path $user_email $max_depth $item_type $remote_name
    }
}

proc scan_shared_folders_user_impl {path user_email max_depth item_type remote_name} {
    # Internal implementation of recursive user scan (renamed from scan_shared_folders_user)
    puts "🔍 Scanning for items with user access: $user_email"
    puts "Starting path: $path"
    puts "Max depth: $max_depth"
    puts "Item type: $item_type"
    puts ""
    
    # Get access token
    set access_token [get_access_token $remote_name]
    if {$access_token eq ""} {
        return
    }
    
    puts "✅ Successfully extracted access token from rclone.conf"
    
    set headers [list Authorization "Bearer $access_token"]
    set shared_folders {}
    set checked_folders {}
    set folders_per_level(0) 0
    set target_user_lower [string tolower $user_email]
    
    # Start from specified path or root
    if {[catch {
        if {$path ne "/" && $path ne ""} {
            # Get the target directory by path
            set item_result [cli_get_item_from_path $path $access_token]
            if {[llength $item_result] > 0} {
                lassign $item_result target_id target_data
                
                puts "📂 Starting recursive search from: $path"
                scan_items_recursive $target_id $access_token $max_depth 0 $path "" checked_folders folders_per_level shared_folders "filter" $target_user_lower $item_type
            } else {
                puts "⚠️  Path '$path' not found or not accessible"
                return
            }
        } else {
            # Start from root
            set item_result [cli_get_item_from_path "/" $access_token]
            if {[llength $item_result] > 0} {
                lassign $item_result root_id root_data
                
                puts "📂 Starting recursive search from root..."
                scan_items_recursive $root_id $access_token $max_depth 0 "" "" checked_folders folders_per_level shared_folders "filter" $target_user_lower $item_type
            } else {
                puts "⚠️  Failed to get root"
                return
            }
        }
    } error]} {
        puts "❌ Search error: $error"
    }
    
    # Print level statistics
    puts "\n📊 Folder count by level:"
    foreach level [lsort -integer [array names folders_per_level]] {
        set count $folders_per_level($level)
        puts "   Level $level: $count folders"
    }
    
    puts "\n✅ Scan complete. Found [llength $shared_folders] shared folders."
    puts "   Checked [llength $checked_folders] total folders recursively."
    
    # Display results
    if {[llength $shared_folders] > 0} {
        puts "\n[string repeat "=" 80]"
        puts "📁 Found [llength $shared_folders] shared folder(s):"
        puts [string repeat "=" 80]
        
        foreach folder $shared_folders {
            set folder_path [dict get $folder path]
            set symbol [dict get $folder symbol]
            set share_type [dict get $folder share_type]
            set perm_count [dict get $folder permission_count]
            set shared_users [dict get $folder shared_users]
            
            puts "$symbol $folder_path"
            puts "   └─ $share_type ($perm_count permission(s))"
            
            if {[llength $shared_users] > 0} {
                # Move the search user to the front if present
                set search_user_index [lsearch -exact $shared_users $user_email]
                if {$search_user_index >= 0} {
                    set search_user [lindex $shared_users $search_user_index]
                    set other_users [lreplace $shared_users $search_user_index $search_user_index]
                    set reordered_users [linsert $other_users 0 $search_user]
                } else {
                    set reordered_users $shared_users
                }
                
                set users_str [join [lrange $reordered_users 0 2] ", "]
                if {[llength $reordered_users] > 3} {
                    set users_str "$users_str and [expr [llength $reordered_users] - 3] more"
                }
                puts "   └─ Shared with: $users_str"
            }
            
            set has_link [dict get $folder has_link_sharing]
            set has_direct [dict get $folder has_direct_sharing]
            if {$has_link && $has_direct} {
                puts "   └─ Has both link sharing and direct permissions"
            }
            puts ""
        }
    } else {
        puts "\nℹ️  No shared folders found"
        puts "This could mean:"
        puts "  - No folders are shared with $user_email"
        puts "  - The user email '$user_email' doesn't match any shared users"
    }
    
    puts "\n=== Scan Complete ==="
}

proc fetch_acl {{item_path ""} {remote_name "OneDrive"} {target_dir ""}} {
    global remote_entry tree gui_mode current_folder_path current_item_id token_capability action_buttons_frame
    
    if {$gui_mode} {
        set remote_name [$remote_entry get]
    }
    
    if {$item_path eq ""} {
        update_status "Error: Please select an item to fetch ACL" red
        return
    }
    
    update_status "Fetching ACL for: $item_path" blue
    
    # Clear existing treeview
    clear_treeview
    
    # Get access token with capability detection
    set result [get_access_token_with_capability $remote_name]
    set access_token [lindex $result 0]
    set capability [lindex $result 1]
    set expires_at [lindex $result 2]
    set token_capability $capability
    
    if {$access_token eq ""} {
        return
    }
    
    debug_log "Token capability: $capability"
    
    # Format expiration info for status message
    if {$expires_at ne "unknown" && $expires_at ne "n/a"} {
        set exp_display " (expires: $expires_at)"
    } else {
        set exp_display ""
    }
    
    update_status "✅ Using token (capability: $capability)$exp_display" green
    
    # Construct the full path if target_dir is specified
    set full_path $item_path
    if {$target_dir ne ""} {
        set full_path "$target_dir/$item_path"
    }
    
    # Get item info - URL encode the path properly for all Unicode characters
    set item_url [get_item_url_from_path $full_path]
    update_status "Getting item info from: $item_url" blue
    
    set result [make_http_request $item_url [list Authorization "Bearer $access_token"]]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status ne "200"} {
        # Handle 401 errors specially - token might have expired
        if {$status eq "401" && $capability eq "full" && [string match "*TOKEN_EXPIRED*" $data]} {
            update_status "❌ Token expired despite refresh attempt. Please re-authenticate." red
            return
        } elseif {$status eq "error"} {
            update_status "❌ HTTP request failed: $data" red
        } else {
            update_status "❌ Failed to get item info: $status - $data" red
        }
        return
    }
    
    # Parse item response
    if {[catch {json::json2dict $data} item_dict]} {
        update_status "❌ Failed to parse item response: $item_dict" red
        return
    }
    
    set item_id [dict get $item_dict id]
    set item_name [dict get $item_dict name]
    set item_type [expr {[dict exists $item_dict folder] ? "folder" : "file"}]
    
    # Store current item ID for edit operations
    set current_item_id $item_id
    
    update_status "✅ Found $item_type: $item_name (ID: $item_id)" green
    
    # Get permissions
    set permissions_url [build_graph_api_url "/me/drive/items/$item_id/permissions"]
    update_status "Getting ACL from: $permissions_url" blue
    
    set result [make_http_request $permissions_url [list Authorization "Bearer $access_token"]]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status ne "200"} {
        if {$status eq "403"} {
            update_status "❌ Access denied - you may not have permission to view ACL for this item" red
        } else {
            update_status "❌ Failed to get ACL: $status" red
        }
        return
    }
    
    # Parse permissions response
    if {[catch {json::json2dict $data} permissions_dict]} {
        update_status "❌ Failed to parse permissions response: $permissions_dict" red
        return
    }
    
    set permissions [dict get $permissions_dict value]
    set perm_count [llength $permissions]
    
    if {$perm_count == 0} {
        update_status "ℹ️ No permissions found for this item (empty ACL)" orange
        return
    }
    
    update_status "✅ Found $perm_count permission(s) in ACL (Token: $capability)" green
    
    if {$gui_mode} {
        # Enable action buttons now that we have an item selected
        $action_buttons_frame.invite configure -state normal
        $action_buttons_frame.remove configure -state disabled  ;# Will be enabled when user selects items
        
        # Bind treeview selection event to enable/disable Remove button
        bind $tree <<TreeviewSelect>> {
            global action_buttons_frame tree
            set selection [$tree selection]
            if {[llength $selection] > 0} {
                $action_buttons_frame.remove configure -state normal
            } else {
                $action_buttons_frame.remove configure -state disabled
            }
        }
        
        # Populate treeview (filter out owner permissions)
        set perm_num 1
        foreach perm $permissions {
            set roles [dict get $perm roles]
            
            # Skip owner permissions - they can't be removed and OneDrive doesn't show them
            if {[lsearch $roles "owner"] >= 0} {
                continue
            }
            
            set perm_id [dict get $perm id]
            set roles_str [join $roles ", "]
            
            # Get user information
            lassign [extract_user_info $perm] user_name user_email
            
            # Get link information
            set link_type "N/A"
            set link_scope "N/A"
            if {[dict exists $perm link]} {
                set link [dict get $perm link]
                if {[dict exists $link type]} {
                    set link_type [dict get $link type]
                }
                if {[dict exists $link scope]} {
                    set link_scope [dict get $link scope]
                }
            }
            
            # Get expiration
            set expires "N/A"
            if {[dict exists $perm expirationDateTime]} {
                set expires [dict get $perm expirationDateTime]
            }
            
            # Determine tag based on roles
            set tag "write"
            if {[lsearch $roles "read"] >= 0} {
                set tag "read"
            }
            
            # Insert into treeview
            $tree insert {} end -text "$perm_num" \
                -values [list $perm_id $roles_str $user_name $user_email $link_type $link_scope $expires] \
                -tags $tag
            
            incr perm_num
        }
    } else {
        # Display in CLI mode
        display_acl_cli $permissions $item_id
    }
    
    update_status "✅ ACL listing of: https://onedrive.live.com/?id=$item_id" green
}

if {$gui_mode} {
    # GUI mode - Initialize browser with root folder
    update_status "OneDrive ACL Lister - Ready to browse and fetch ACL information" blue
    
    # Populate first column with root folder
    populate_column 0 "root" ""
} else {
    # CLI mode - process command line arguments with path-first interface
    # Usage: [PATH] [OPTIONS]
    
    # Show help function
    proc show_usage {} {
        puts "Usage: tclsh acl-inspector.tcl \[PATH\] \[OPTIONS\]"
        puts ""
        puts "PATH: Item to inspect (default: /)"
        puts ""
        puts "Options:"
        puts "  --only-user USER       Filter to items USER has access to"
        puts "  --remove-user USER     Remove USER's access (destructive)"
        puts "  --invite USER          Invite USER with read/write access (inherited by children)"
        puts "  -r, --recursive        Include children in scan"
        puts "  --max-depth N          Max depth (default: 3, requires -r or explicit setting)"
        puts "  --type TYPE            folders|files|both (default: folders)"
        puts "  --dry-run              Preview changes (with --remove-user)"
        puts "  --read-only            Grant read-only access (with --invite, default: read/write)"
        puts "  --debug                Enable debug output"
        puts "  --remote REMOTE        OneDrive remote (default: OneDrive)"
        puts ""
        puts "Examples:"
        puts "  tclsh acl-inspector.tcl \"Work\""
        puts "  tclsh acl-inspector.tcl \"Work\" --only-user bob@example.com -r"
        puts "  tclsh acl-inspector.tcl \"Projects\" --invite alice@example.com"
        puts "  tclsh acl-inspector.tcl \"Projects\" --invite bob@example.com --read-only"
        puts "  tclsh acl-inspector.tcl \"Projects\" --remove-user ex@example.com -r --dry-run"
        puts "  tclsh acl-inspector.tcl --only-user bob@example.com -r --type both"
        exit 1
    }
    
    if {![info exists argv] || [llength $argv] == 0} {
        show_usage
    }
    
    # Initialize variables
    set path ""
    set only_user ""
    set remove_user ""
    set invite_user ""
    set max_depth 0
    set item_type "folders"
    set dry_run 0
    set read_only 0
    set remote_name "OneDrive"
    set r_flag_used 0
    set max_depth_explicit 0
    
    # Debug mode will be set if --debug flag is provided
    global debug_mode
    set debug_mode 0
    
    # First pass: extract PATH (first non-flag argument)
    set i 0
    while {$i < [llength $argv]} {
        set arg [lindex $argv $i]
        if {$arg eq "--help" || $arg eq "-h"} {
            show_usage
        } elseif {[string index $arg 0] ne "-" && $path eq ""} {
            set path $arg
            break
        }
        incr i
    }
    
    # If no path found, default to root
    if {$path eq ""} {
        set path "/"
    }
    
    # Second pass: parse all flags
    set i 0
    while {$i < [llength $argv]} {
        set arg [lindex $argv $i]
        
        if {$arg eq "--only-user" && $i + 1 < [llength $argv]} {
            set only_user [lindex $argv [expr $i + 1]]
            incr i 2
        } elseif {$arg eq "--remove-user" && $i + 1 < [llength $argv]} {
            set remove_user [lindex $argv [expr $i + 1]]
            incr i 2
        } elseif {$arg eq "--invite" && $i + 1 < [llength $argv]} {
            set invite_user [lindex $argv [expr $i + 1]]
            incr i 2
        } elseif {$arg eq "-r" || $arg eq "--recursive"} {
            set r_flag_used 1
            if {!$max_depth_explicit} {
                set max_depth 3
            }
            incr i
        } elseif {$arg eq "--max-depth" && $i + 1 < [llength $argv]} {
            set max_depth [lindex $argv [expr $i + 1]]
            set max_depth_explicit 1
            incr i 2
        } elseif {$arg eq "--type" && $i + 1 < [llength $argv]} {
            set item_type [lindex $argv [expr $i + 1]]
            incr i 2
        } elseif {$arg eq "--dry-run"} {
            set dry_run 1
            incr i
        } elseif {$arg eq "--read-only"} {
            set read_only 1
            incr i
        } elseif {$arg eq "--debug"} {
            set debug_mode 1
            incr i
        } elseif {$arg eq "--remote" && $i + 1 < [llength $argv]} {
            set remote_name [lindex $argv [expr $i + 1]]
            incr i 2
        } elseif {[string index $arg 0] ne "-"} {
            # Skip PATH if already processed
            incr i
        } else {
            puts "Error: Unknown option '$arg'"
            puts ""
            show_usage
        }
    }
    
    # Validation: mutual exclusions
    set action_count 0
    if {$only_user ne ""} { incr action_count }
    if {$remove_user ne ""} { incr action_count }
    if {$invite_user ne ""} { incr action_count }
    
    if {$action_count > 1} {
        puts "Error: --only-user, --remove-user, and --invite are mutually exclusive"
        exit 1
    }
    
    # Validate --invite is not used with recursive flags
    if {$invite_user ne "" && ($r_flag_used || $max_depth_explicit)} {
        puts "Error: --invite cannot be used with -r or --max-depth (invitations are always inherited)"
        exit 1
    }
    
    # Validate --dry-run only with --remove-user
    if {$dry_run && $remove_user eq ""} {
        puts "Error: --dry-run can only be used with --remove-user"
        exit 1
    }
    
    # Validate --read-only only with --invite
    if {$read_only && $invite_user eq ""} {
        puts "Error: --read-only can only be used with --invite"
        exit 1
    }
    
    # Validate --type values
    if {$item_type ne "folders" && $item_type ne "files" && $item_type ne "both"} {
        puts "Error: --type must be 'folders', 'files', or 'both'"
        exit 1
    }
    
    # If -r was used without explicit --max-depth, inform user
    if {$max_depth == 3 && $r_flag_used && !$max_depth_explicit} {
        puts "ℹ️  Using default max-depth: 3 (use --max-depth N to change)"
        puts ""
    }
    
    # Execute based on flags
    if {$invite_user ne ""} {
        # Invite user to path
        invite_user_cli $path $invite_user $read_only $remote_name
    } elseif {$remove_user ne ""} {
        # Remove user permissions
        remove_user_permissions_cli $path $remove_user $max_depth $item_type $dry_run $remote_name
    } elseif {$only_user ne ""} {
        # List user access
        list_user_access $path $only_user $max_depth $item_type $remote_name
    } else {
        # Default: show ACL with new recursive format
        puts "OneDrive ACL Inspector"
        puts "Path: $path"
        puts "Remote: $remote_name"
        if {$max_depth > 0} {
            puts "Max depth: $max_depth"
        }
        puts ""
        
        # Get access token with capability detection and auto-refresh
        set result [get_access_token_with_capability $remote_name]
        set access_token [lindex $result 0]
        set capability [lindex $result 1]
        
        if {$access_token eq ""} {
            puts "❌ Failed to get access token"
            exit 1
        }
        
        puts "✅ Using token (capability: $capability)"
        puts ""
        
        # Get starting item ID
        set item_url [get_item_url_from_path $path]
        
        set headers [list Authorization "Bearer $access_token"]
        set result [make_http_request $item_url $headers]
        set status [lindex $result 0]
        set data [lindex $result 1]
        
        if {$status ne "200"} {
            puts "❌ Failed to get item: $status"
            if {$status eq "error"} {
                puts "Error details: $data"
            }
            exit 1
        }
        
        set item_dict [json::json2dict $data]
        set start_id [dict get $item_dict id]
        
        # Collect all folder permissions recursively
        set all_folders {}
        set checked_folders {}
        set folders_per_level(0) 0
        
        if {$max_depth > 0} {
            puts "🔍 Scanning folder hierarchy (max depth: $max_depth)..."
            puts ""
        }
        
        # Set effective max_depth (if 0, scan only root; otherwise use the specified depth)
        set effective_max_depth [expr {$max_depth == 0 ? 1 : $max_depth}]
        
        scan_items_recursive $start_id $access_token $effective_max_depth 0 $path "" checked_folders folders_per_level all_folders "collect_all" "" $item_type
        
        if {$max_depth > 0} {
            puts ""
            puts "✅ Scan complete. Scanned [llength $checked_folders] folder(s)."
        }
        
        # Get root permissions
        if {[llength $all_folders] > 0} {
            set root_folder [lindex $all_folders 0]
            set root_permissions [dict get $root_folder permissions]
            
            # Display using new recursive format
            display_recursive_acl $path $root_permissions $all_folders $max_depth
        } else {
            puts "❌ No folders found or unable to access permissions"
        }
    }
} 