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
    # Log other errors
    debug_log "Background error: $message"
}

# Global variables
set debug_mode 1  ;# Set to 1 to enable debug logging
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
    
    # Get access token
    set access_token [get_access_token [$remote_entry get]]
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
# Legacy Utility Functions
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

proc get_access_token {rclone_remote} {
    set conf_path [file join ~ .config rclone rclone.conf]
    
    if {![file exists $conf_path]} {
        update_status "Error: rclone config not found at $conf_path" red
        return ""
    }
    
    # Read config file
    set config_data [read [open $conf_path r]]
    
    # Find the remote section
    set remote_section ""
    set in_remote_section 0
    
    foreach line [split $config_data \n] {
        if {[string match "\\\[$rclone_remote\\\]" [string trim $line]]} {
            set in_remote_section 1
            continue
        }
        
        if {$in_remote_section} {
            if {[string match "\\\[*\\\]" [string trim $line]]} {
                break
            }
            if {[string match "token*" [string trim $line]]} {
                set token_line [string trim $line]
                set token_json [string range $token_line 6 end]
                break
            }
        }
    }
    
    if {![info exists token_json]} {
        update_status "Error: No token found for remote '$rclone_remote'" red
        return ""
    }
    
    # Parse JSON token
    set access_token ""
    if {[catch {json::json2dict $token_json} token_dict] == 0} {
        set access_token [dict get $token_dict access_token]
        if {$access_token eq ""} {
            update_status "Error: No access_token in token JSON" red
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

proc get_access_token_with_capability {rclone_remote} {
    # Get access token and determine capability level
    # Returns: {access_token capability_level}
    # capability_level: "full", "read-only", or "unknown"
    
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
            # Successfully parsed, now check capability and extract token
            if {[dict exists $token_data access_token]} {
                set capability [check_token_capability $token_data]
                set access_token [dict get $token_data access_token]
                
                debug_log "Token capability: $capability"
                debug_log "Using token.json with capability: $capability"
                
                return [list $access_token $capability]
            } else {
                debug_log "ERROR: No access_token in parsed JSON"
            }
        } else {
            debug_log "Error reading token.json: $parse_error, falling back to rclone.conf"
        }
    }
    
    # Fallback to rclone.conf (assume read-only)
    set access_token [get_access_token $rclone_remote]
    if {$access_token ne ""} {
        debug_log "Using rclone.conf token (read-only mode)"
        return [list $access_token "read-only"]
    }
    
    return [list "" "unknown"]
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
    # Orchestrate full OAuth flow
    global oauth gui_mode
    
    update_status "Starting OAuth authentication..." blue
    
    # Start local server
    if {[oauth_start_local_server] eq ""} {
        return 0
    }
    
    # Build auth URL and open browser
    set auth_url [oauth_build_auth_url]
    
    update_status "Opening browser for authentication..." blue
    
    # Open browser (platform-specific)
    set browser_error 0
    if {[catch {
        if {$::tcl_platform(platform) eq "windows"} {
            exec cmd /c start $auth_url &
        } elseif {$::tcl_platform(os) eq "Darwin"} {
            exec open $auth_url &
        } else {
            exec xdg-open $auth_url &
        }
    } error] != 0} {
        update_status "Error opening browser: $error" red
        global serverSock
        if {$serverSock ne ""} {
            catch {close $serverSock}
            set serverSock ""
        }
        set browser_error 1
    }
    
    if {$browser_error} {
        return 0
    }
    
    update_status "Waiting for authentication in browser..." blue
    
    # Wait for callback (with timeout)
    set timeout_ms 120000  ;# 2 minutes
    set start_time [clock milliseconds]
    
    while {$oauth(auth_code) eq ""} {
        # Check if main window still exists
        if {![winfo exists .]} {
            # Window was closed, clean up and exit
            debug_log "Main window destroyed during OAuth wait"
            global serverSock
            if {$serverSock ne ""} {
                catch {close $serverSock}
                set serverSock ""
            }
            exit 0
        }
        
        # Try to update event loop, handle errors gracefully
        set update_error 0
        if {[catch {update} error] != 0} {
            # Event loop failed, clean up
            debug_log "Event loop error during OAuth wait: $error"
            global serverSock
            if {$serverSock ne ""} {
                catch {close $serverSock}
                set serverSock ""
            }
            set update_error 1
        }
        
        if {$update_error} {
            return 0
        }
        
        after 100
        
        if {[expr {[clock milliseconds] - $start_time}] > $timeout_ms} {
            update_status "Authentication timeout - please try again" red
            global serverSock
            if {$serverSock ne ""} {
                catch {close $serverSock}
                set serverSock ""
            }
            return 0
        }
    }
    
    # Check if authentication was cancelled
    if {$oauth(auth_code) eq "CANCELLED"} {
        debug_log "OAuth flow cancelled by user"
        update_status "Authentication cancelled" orange
        set oauth(auth_code) ""
        return 0
    }
    
    update_status "Exchanging authorization code for token..." blue
    
    # Exchange code for token
    set success 0
    set error_message ""
    
    if {[catch {
        set token_dict [oauth_exchange_token $oauth(auth_code)]
        save_token_json $token_dict
        
        # Reset auth code
        set oauth(auth_code) ""
        
        update_status "✅ Token acquired successfully!" green
        
        # Update capability and enable edit mode
        global token_capability remote_entry
        debug_log "About to call get_access_token_with_capability..."
        set result [get_access_token_with_capability [$remote_entry get]]
        debug_log "get_access_token_with_capability returned: $result"
        set token_capability [lindex $result 1]
        debug_log "Token capability set to: $token_capability"
        
        update_status "✅ Token acquired and saved successfully!" green
        
        set success 1
    } error_message]} {
        debug_log "ERROR in acquire_elevated_token catch block: $error_message"
        update_status "Token exchange failed: $error_message" red
        set oauth(auth_code) ""
        set success 0
    }
    
    return $success
}

proc make_http_request {url headers {method GET} {body ""}} {
    # Enhanced HTTP request supporting GET, POST, DELETE
    set token [dict get $headers Authorization]
    
    puts "DEBUG: HTTP $method Request to: $url"
    
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
        
        puts "DEBUG: HTTP Response status: $status"
        if {$status ne "200" && $status ne "201" && $status ne "204"} {
            puts "ERROR: HTTP $status - URL: $url"
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
    # Check if we have edit capability, prompt for OAuth if needed
    # Returns: 1 if we have edit capability, 0 if user cancelled or failed
    global token_capability remote_entry
    
    # Get current token capability
    set result [get_access_token_with_capability [$remote_entry get]]
    set access_token [lindex $result 0]
    set capability [lindex $result 1]
    set token_capability $capability
    
    if {$capability eq "full"} {
        # Already have edit capability
        return 1
    }
    
    # Need to acquire elevated token
    set response [tk_messageBox -type yesno -icon question \
        -title "Elevated Permissions Required" \
        -message "This operation requires elevated OneDrive permissions.\n\nWould you like to authenticate in your browser to acquire an editing token?"]
    
    if {$response eq "yes"} {
        # Start OAuth flow
        if {[acquire_elevated_token]} {
            return 1
        } else {
            return 0
        }
    }
    
    return 0
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
    wm geometry $dialog "400x200"
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
            set encoded_path [url_encode $folder_path]
            set path_url [build_graph_api_url "/me/drive/root:/$encoded_path"]
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

proc check_folder_recursive {folder_id access_token target_user_lower max_depth current_depth folder_path checked_folders folders_per_level shared_folders} {
    # Recursively check a folder and all its subfolders for sharing
    upvar $checked_folders checked
    upvar $folders_per_level folders
    upvar $shared_folders shared
    
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
            # Analyze permissions
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
                
                add_shared_folder_result $folder_id $folder_path $access_token $has_link $has_direct $perm_count $shared_users $target_user_lower shared
            }
            
            # Implement pruning: if explicit user permission found, skip children
            if {$target_user_lower ne "" && $has_explicit_user_perm} {
                puts "   🚀 Pruning: Found explicit permission, skipping subfolders (inherited)"
                return
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
                if {[dict exists $child folder]} {
                    set child_id [dict get $child id]
                    set child_name [dict get $child name]
                    set child_path "$folder_path/$child_name"
                    if {$folder_path eq ""} {
                        set child_path $child_name
                    }
                    
                    # Recursively check this child folder
                    check_folder_recursive $child_id $access_token $target_user_lower $max_depth [expr $current_depth + 1] $child_path checked folders shared
                }
            }
        }
        
    } error]} {
        # Skip folders we can't access
    }
}

proc scan_shared_folders_user {user_email remote_name max_depth target_dir} {
    # Scan OneDrive for folders explicitly shared with a specific user
    puts "🔍 Scanning OneDrive for folders shared with user: $user_email"
    puts "Max depth: $max_depth"
    if {$target_dir ne ""} {
        puts "Target directory: $target_dir"
    }
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
    
    # Start from target directory or root
    if {[catch {
        if {$target_dir ne ""} {
            # Get the target directory by path - URL encode the path
            set encoded_dir [url_encode $target_dir]
            set target_url [build_graph_api_url "/me/drive/root:/$encoded_dir"]
            set result [make_http_request $target_url $headers]
            set status [lindex $result 0]
            set data [lindex $result 1]
            
            if {$status eq "200"} {
                set target_data [json::json2dict $data]
                set target_id [dict get $target_data id]
                
                puts "📂 Starting recursive search from directory: $target_dir"
                check_folder_recursive $target_id $access_token $target_user_lower $max_depth 0 $target_dir checked_folders folders_per_level shared_folders
            } else {
                puts "⚠️  Target directory '$target_dir' not found or not accessible"
                return
            }
        } else {
            # Start from root
            set root_url [build_graph_api_url "/me/drive/root"]
            set result [make_http_request $root_url $headers]
            set status [lindex $result 0]
            set data [lindex $result 1]
            
            if {$status eq "200"} {
                set root_data [json::json2dict $data]
                set root_id [dict get $root_data id]
                
                puts "📂 Starting recursive search from root..."
                check_folder_recursive $root_id $access_token $target_user_lower $max_depth 0 "" checked_folders folders_per_level shared_folders
            } else {
                puts "⚠️  Failed to get root: $status"
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
            set path [dict get $folder path]
            set symbol [dict get $folder symbol]
            set share_type [dict get $folder share_type]
            set perm_count [dict get $folder permission_count]
            set shared_users [dict get $folder shared_users]
            
            puts "$symbol $path"
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
    puts "💡 Tip: This recursive scan efficiently checks all folders in your OneDrive!"
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
    set token_capability $capability
    
    if {$access_token eq ""} {
        return
    }
    
    debug_log "Token capability: $capability"
    
    update_status "✅ Using token (capability: $capability)" green
    
    # Construct the full path if target_dir is specified
    set full_path $item_path
    if {$target_dir ne ""} {
        set full_path "$target_dir/$item_path"
    }
    
    # Get item info - URL encode the path properly for all Unicode characters
    set encoded_path [url_encode $full_path]
    set item_url [build_graph_api_url "/me/drive/root:/$encoded_path"]
    update_status "Getting item info from: $item_url" blue
    
    set result [make_http_request $item_url [list Authorization "Bearer $access_token"]]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status ne "200"} {
        if {$status eq "error"} {
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
    # CLI mode - process command line arguments
    if {[info exists argv] && [llength $argv] > 0} {
        set subcommand [lindex $argv 0]
        
        if {$subcommand eq "acl"} {
            # ACL subcommand: acl [--remote REMOTE] [--dir PATH] <item_path>
            set remote_name "OneDrive"
            set target_dir ""
            set item_path ""
            set i 1
            
            while {$i < [llength $argv]} {
                set arg [lindex $argv $i]
                if {$arg eq "--remote" && $i + 1 < [llength $argv]} {
                    set remote_name [lindex $argv [expr $i + 1]]
                    incr i 2
                } elseif {$arg eq "--dir" && $i + 1 < [llength $argv]} {
                    set target_dir [lindex $argv [expr $i + 1]]
                    incr i 2
                } elseif {[string index $arg 0] ne "-"} {
                    set item_path $arg
                    incr i
                } else {
                    puts "Unknown option: $arg"
                    puts "Usage: tclsh acl-inspector.tcl acl \[--remote REMOTE\] \[--dir PATH\] <item_path>"
                    exit 1
                }
            }
            
            if {$item_path eq ""} {
                puts "Error: item_path is required"
                puts "Usage: tclsh acl-inspector.tcl acl \[--remote REMOTE\] \[--dir PATH\] <item_path>"
                exit 1
            }
            
            puts "OneDrive ACL Lister - ACL Mode"
        puts "Item Path: $item_path"
        puts "Remote Name: $remote_name"
            if {$target_dir ne ""} {
                puts "Target Directory: $target_dir"
            }
        puts ""
        
        # Fetch ACL
            fetch_acl $item_path $remote_name $target_dir
            
        } elseif {$subcommand eq "user"} {
            # User subcommand: user [--remote REMOTE] [--dir PATH] [--max-depth N] <user_email>
            set remote_name "OneDrive"
            set target_dir ""
            set max_depth 3
            set user_email ""
            set i 1
            
            while {$i < [llength $argv]} {
                set arg [lindex $argv $i]
                if {$arg eq "--remote" && $i + 1 < [llength $argv]} {
                    set remote_name [lindex $argv [expr $i + 1]]
                    incr i 2
                } elseif {$arg eq "--dir" && $i + 1 < [llength $argv]} {
                    set target_dir [lindex $argv [expr $i + 1]]
                    incr i 2
                } elseif {$arg eq "--max-depth" && $i + 1 < [llength $argv]} {
                    set max_depth [lindex $argv [expr $i + 1]]
                    incr i 2
                } elseif {[string index $arg 0] ne "-"} {
                    set user_email $arg
                    incr i
                } else {
                    puts "Unknown option: $arg"
                    puts "Usage: tclsh acl-inspector.tcl user \[--remote REMOTE\] \[--dir PATH\] \[--max-depth N\] <user_email>"
                    exit 1
                }
            }
            
            if {$user_email eq ""} {
                puts "Error: user_email is required"
                puts "Usage: tclsh acl-inspector.tcl user \[--remote REMOTE\] \[--dir PATH\] \[--max-depth N\] <user_email>"
                exit 1
            }
            
            puts "OneDrive ACL Lister - User Scan Mode"
            puts "User Email: $user_email"
            puts "Remote Name: $remote_name"
            puts "Max Depth: $max_depth"
            if {$target_dir ne ""} {
                puts "Target Directory: $target_dir"
            }
            puts ""
            
            # Scan for shared folders
            scan_shared_folders_user $user_email $remote_name $max_depth $target_dir
            
        } else {
            puts "Error: Unknown subcommand '$subcommand'"
            puts "Usage:"
            puts "  tclsh acl-inspector.tcl acl \[--remote REMOTE\] \[--dir PATH\] <item_path>"
            puts "  tclsh acl-inspector.tcl user \[--remote REMOTE\] \[--dir PATH\] \[--max-depth N\] <user_email>"
            exit 1
        }
    } else {
        puts "Usage:"
        puts "  tclsh acl-inspector.tcl acl \[--remote REMOTE\] \[--dir PATH\] <item_path>"
        puts "  tclsh acl-inspector.tcl user \[--remote REMOTE\] \[--dir PATH\] \[--max-depth N\] <user_email>"
        puts ""
        puts "Examples:"
        puts "  tclsh acl-inspector.tcl acl \"✈️ Tourism Transformation\""
        puts "  tclsh acl-inspector.tcl user admin@example.com"
        puts "  tclsh acl-inspector.tcl user --max-depth 5 admin@example.com"
        exit 1
    }
} 