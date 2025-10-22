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
package require tls

# Configure TLS for HTTPS requests
::http::register https 443 [list ::tls::socket]

# Global variables
set access_token ""
set item_path ""
set remote_name "OneDrive"
set current_folder_id "root"
set current_folder_path ""

# GUI widget variables (will be set in GUI mode)
set path_entry ""
set remote_entry ""
set folder_listbox ""

if {$gui_mode} {
    # Declare global widget variables
    global path_entry remote_entry folder_listbox
    
    # Create main window
    wm title . "OneDrive ACL Lister"
    wm geometry . "800x600"
    wm minsize . 600 400

    # Create main frame
    set main_frame [frame .main]
    pack $main_frame -fill both -expand yes -padx 10 -pady 10

    # Create input frame
    set input_frame [frame $main_frame.input]
    pack $input_frame -fill x -pady {0 10}

    # Item path input
    set path_frame [frame $input_frame.path]
    pack $path_frame -fill x -pady 2
    label $path_frame.label -text "OneDrive Item Path:"
    pack $path_frame.label -side left
    set path_entry [entry $path_frame.entry -width 50]
    pack $path_frame.entry -side left -fill x -expand yes -padx {5 0}

    # Remote name input
    set remote_frame [frame $input_frame.remote]
    pack $remote_frame -fill x -pady 2
    label $remote_frame.label -text "Remote Name:"
    pack $remote_frame.label -side left
    set remote_entry [entry $remote_frame.entry -width 20]
    pack $remote_entry -side left -fill x -expand yes -padx {5 0}
    $remote_entry insert 0 "OneDrive"

    # Folder navigation frame
    set folder_frame [frame $main_frame.folder]
    pack $folder_frame -fill both -expand yes -pady {0 10}

    # Folder listbox
    label $folder_frame.label -text "Remote Folders:"
    pack $folder_frame.label -anchor w -pady {0 5}

    set folder_container [frame $folder_frame.container]
    pack $folder_container -fill both -expand yes

    set folder_listbox [listbox $folder_container.listbox -height 8]
    pack $folder_listbox -side left -fill both -expand yes

    # Folder listbox scrollbar
    set folder_scrollbar [scrollbar $folder_container.scroll -orient vertical -command "$folder_listbox yview"]
    pack $folder_scrollbar -side right -fill y
    $folder_listbox configure -yscrollcommand "$folder_scrollbar set"

    # Status label
    set status_label [label $main_frame.status -text "Ready" -fg blue]
    pack $status_label -fill x -pady {0 10}

    # Create treeview frame
    set tree_frame [frame $main_frame.tree]
    pack $tree_frame -fill both -expand yes

    # Create treeview with scrollbars
    set tree_container [frame $tree_frame.container]
    pack $tree_container -fill both -expand yes

    # Treeview widget
    set tree [ttk::treeview $tree_container.tree -columns {id roles user email link_type link_scope expires} -show {tree headings}]
    pack $tree -side left -fill both -expand yes

    # Scrollbars
    set v_scrollbar [scrollbar $tree_container.vscroll -orient vertical -command "$tree yview"]
    pack $v_scrollbar -side right -fill y
    $tree configure -yscrollcommand "$v_scrollbar set"

    set h_scrollbar [scrollbar $tree_frame.hscroll -orient horizontal -command "$tree xview"]
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

proc update_status {message {color blue}} {
    global status_label gui_mode
    if {$gui_mode} {
        $status_label configure -text $message -fg $color
        puts "GUI STATUS: $message (color: $color)"
    } else {
        puts "STATUS: $message"
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

# Navigation functions for folder browsing
proc load_folder_contents {folder_id folder_path} {
    global current_folder_id current_folder_path folder_listbox path_entry access_token gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    puts "GUI: Loading folder contents - ID: '$folder_id', Path: '$folder_path'"
    
    set current_folder_id $folder_id
    set current_folder_path $folder_path
    
    # Update path display
    $path_entry delete 0 end
    $path_entry insert 0 $folder_path
    
    # Clear and populate folder list
    $folder_listbox delete 0 end
    
    # Add navigation entries
    if {$folder_id ne "root"} {
        $folder_listbox insert end ".."
    }
    
    # Show loading indicator
    $folder_listbox insert end "Loading..."
    update
    
    # Fetch folder contents from OneDrive API
    fetch_remote_folder_contents $folder_id
}

proc fetch_remote_folder_contents {folder_id} {
    global access_token folder_listbox remote_entry gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    puts "GUI: Fetching remote folder contents for ID: $folder_id"
    
    # Get access token
    set access_token [get_access_token [$remote_entry get]]
    if {$access_token eq ""} {
        puts "GUI: No access token available"
        $folder_listbox delete 0 end
        $folder_listbox insert end "❌ No access token"
        update_status "No access token available" red
        return
    }
    
    puts "GUI: Got access token, making API request for children..."
    
    # Make API call to get children
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
        # Clear loading indicator
        $folder_listbox delete 0 end
        
        # Add navigation entries
        if {$folder_id ne "root"} {
            $folder_listbox insert end ".."
        }
        
        # Parse and add folder entries
        set children_dict [json::json2dict $data]
        set children [dict get $children_dict value]
        
        foreach child $children {
            if {[dict exists $child folder]} {
                set child_name [dict get $child name]
                $folder_listbox insert end $child_name
            }
        }
        
        # Auto-fetch ACL for current folder
        fetch_acl_for_current_folder
    } else {
        # Show error
        $folder_listbox delete 0 end
        $folder_listbox insert end "❌ Error loading folders"
        if {$status eq "error"} {
            $folder_listbox insert end "Network error: $data"
        } else {
            $folder_listbox insert end "HTTP $status: $data"
        }
    }
}

proc navigate_to_folder {folder_name} {
    global current_folder_id current_folder_path folder_listbox gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    # Handle navigation entries
    if {$folder_name eq ".."} {
        # Go to parent folder
        if {$current_folder_id ne "root"} {
            # Get parent folder ID by going up one level
            go_to_parent_folder
        }
        return
    }
    
    # No prefix to remove - folder names are stored directly
    
    # Find the folder ID and navigate into it
    find_and_navigate_to_folder $folder_name
}

proc go_to_parent_folder {} {
    global current_folder_id current_folder_path access_token gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    # Get current folder info to find parent
    set headers [list Authorization "Bearer $access_token"]
    set item_url "https://graph.microsoft.com/v1.0/me/drive/items/$current_folder_id"
    
    set result [make_http_request $item_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status eq "200"} {
        set item_data [json::json2dict $data]
        if {[dict exists $item_data parentReference]} {
            set parent_ref [dict get $item_data parentReference]
            if {[dict exists $parent_ref id]} {
                set parent_id [dict get $parent_ref id]
                # Check if this is the root
                if {[dict exists $parent_ref path] && [dict get $parent_ref path] eq "/drive/root:"} {
                    set parent_id "root"
                }
                
                # Update path
                set new_path [file dirname $current_folder_path]
                if {$new_path eq "."} {
                    set new_path ""
                }
                
                load_folder_contents $parent_id $new_path
            }
        }
    }
}

proc find_and_navigate_to_folder {folder_name} {
    global current_folder_id current_folder_path access_token gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    # Get current folder contents to find the folder ID
    set headers [list Authorization "Bearer $access_token"]
    if {$current_folder_id eq "root"} {
        set children_url "https://graph.microsoft.com/v1.0/me/drive/root/children"
    } else {
        set children_url "https://graph.microsoft.com/v1.0/me/drive/items/$current_folder_id/children"
    }
    
    set result [make_http_request $children_url $headers]
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    if {$status eq "200"} {
        set children_dict [json::json2dict $data]
        set children [dict get $children_dict value]
        
        foreach child $children {
            if {[dict exists $child folder]} {
                set child_name [dict get $child name]
                if {$child_name eq $folder_name} {
                    set child_id [dict get $child id]
                    set new_path $current_folder_path
                    if {$new_path ne ""} {
                        set new_path "$new_path/$folder_name"
                    } else {
                        set new_path $folder_name
                    }
                    load_folder_contents $child_id $new_path
                    return
                }
            }
        }
        update_status "Folder '$folder_name' not found" red
    }
}

proc fetch_acl_for_current_folder {} {
    global current_folder_path gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    if {$current_folder_path ne ""} {
        fetch_acl $current_folder_path
    } else {
        # For root folder, we need to get the root folder ID
        fetch_acl ""
    }
}

proc navigate_to_typed_path {path} {
    global remote_entry gui_mode
    
    if {!$gui_mode} {
        return
    }
    
    puts "GUI: Navigating to typed path: '$path'"
    
    # Navigate to the typed path by getting the folder ID
    set access_token [get_access_token [$remote_entry get]]
    if {$access_token eq ""} {
        puts "GUI: No access token available"
        update_status "No access token available" red
        return
    }
    
    puts "GUI: Got access token, making API request..."
    
    # Get item info for the typed path
    set headers [list Authorization "Bearer $access_token"]
    set encoded_path [string map {" " "%20"} $path]
    set item_url "https://graph.microsoft.com/v1.0/me/drive/root:/$encoded_path"
    
    puts "GUI: API URL: $item_url"
    
    # Use the existing make_http_request function
    set result [make_http_request $item_url $headers]
    
    set status [lindex $result 0]
    set data [lindex $result 1]
    
    puts "GUI: API response status: $status"
    
    if {$status eq "200"} {
        set item_data [json::json2dict $data]
        if {[dict exists $item_data folder]} {
            set folder_id [dict get $item_data id]
            puts "GUI: Found folder ID: $folder_id"
            load_folder_contents $folder_id $path
        } else {
            puts "GUI: Path '$path' is not a folder"
            update_status "Path '$path' is not a folder" red
        }
    } else {
        puts "GUI: Path '$path' not found - Status: $status, Data: $data"
        update_status "Path '$path' not found" red
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
        set user_name "N/A"
        set user_email "N/A"
        
        if {[dict exists $perm grantedTo user]} {
            set user [dict get $perm grantedTo user]
            set user_name [dict get $user displayName]
            set user_email [dict get $user email]
        } elseif {[dict exists $perm grantedToIdentities]} {
            set identities [dict get $perm grantedToIdentities]
            if {[llength $identities] > 0} {
                set identity [lindex $identities 0]
                if {[dict exists $identity user]} {
                    set user [dict get $identity user]
                    set user_name [dict get $user displayName]
                    set user_email [dict get $user email]
                }
            }
        }
        
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
    if {[catch {json::json2dict $token_json} token_dict]} {
        update_status "Error: Could not parse token JSON: $token_dict" red
        return ""
    }
    
    set access_token [dict get $token_dict access_token]
    if {$access_token eq ""} {
        update_status "Error: No access_token in token JSON" red
        return ""
    }
    
    return $access_token
}

proc make_http_request {url headers} {
    set token [dict get $headers Authorization]
    
    if {[catch {
        set response [http::geturl $url -headers [list Authorization $token] -timeout 30000]
        set status [http::ncode $response]
        set data [http::data $response]
        http::cleanup $response
        set result [list $status $data]
    } error]} {
        set result [list "error" $error]
    }
    return $result
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
        set roles [dict get $perm roles]
        if {[lsearch $roles "owner"] >= 0} {
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
            set user [dict get $perm grantedTo user]
            set has_direct_sharing 1
            set email [dict get $user email]
            if {$email eq ""} {
                set email [dict get $user displayName]
            }
            if {$email ne "" && [lsearch $shared_users $email] < 0} {
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
            return [join $path_parts "/"]
        } else {
            return "Unknown"
        }
    } error]} {
        return "Unknown"
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
        set permissions_url "https://graph.microsoft.com/v1.0/me/drive/items/$folder_id/permissions"
        set headers [list Authorization "Bearer $access_token"]
        set result [make_http_request $permissions_url $headers]
        set status [lindex $result 0]
        set data [lindex $result 1]
        
        if {$status eq "200"} {
            set permissions_data [json::json2dict $data]
            set permissions [dict get $permissions_data value]
            
            # Analyze permissions
            set analysis [analyze_permissions $permissions]
            set has_link [lindex $analysis 0]
            set has_direct [lindex $analysis 1]
            set perm_count [lindex $analysis 2]
            set shared_users [lindex $analysis 3]
            
            # Check for explicit user permissions if target_user is specified
            set has_explicit_user_permission 0
            if {$target_user_lower ne ""} {
                foreach perm $permissions {
                    # Skip owner permissions
                    set roles [dict get $perm roles]
                    if {[lsearch $roles "owner"] >= 0} {
                        continue
                    }
                    
                    # Check if this permission is inherited (has inheritedFrom property)
                    if {[dict exists $perm inheritedFrom]} {
                        continue
                    }
                    
                    # Check direct user permissions
                    if {[dict exists $perm grantedTo user]} {
                        set user [dict get $perm grantedTo user]
                        set user_email [string tolower [dict get $user email]]
                        if {[string first $target_user_lower $user_email] >= 0} {
                            set has_explicit_user_permission 1
                            break
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
                                    set has_explicit_user_permission 1
                                    break
                                }
                            }
                        }
                    }
                    
                    if {$has_explicit_user_permission} {
                        break
                    }
                }
            }
            
            # Determine if this folder should be included in results
            set should_include_folder 0
            if {$target_user_lower ne ""} {
                # When filtering by user, only include if explicit permission found
                set should_include_folder $has_explicit_user_permission
            } else {
                # When not filtering by user, include all shared folders
                set should_include_folder [expr {$has_link || $has_direct}]
            }
            
            if {$should_include_folder} {
                # Get full path if not already provided
                if {$folder_path eq ""} {
                    set folder_path [get_item_path $folder_id $access_token]
                }
                
                # Get folder name
                set folder_info_url "https://graph.microsoft.com/v1.0/me/drive/items/$folder_id"
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
                        set path_url "https://graph.microsoft.com/v1.0/me/drive/root:/$folder_path"
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
                
                if {$target_user_lower ne "" && $has_explicit_user_permission} {
                    puts "   ✅ Found explicit permission: $symbol $folder_path"
                } else {
                    puts "   ✅ Found shared: $symbol $folder_path"
                }
            }
            
            # Implement pruning: if explicit user permission found, skip children
            if {$target_user_lower ne "" && $has_explicit_user_permission} {
                puts "   🚀 Pruning: Found explicit permission, skipping subfolders (inherited)"
                return
            }
        }
        
        # Get children of this folder and recursively check them
        set children_url "https://graph.microsoft.com/v1.0/me/drive/items/$folder_id/children"
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
            set encoded_dir [string map {" " "%20" "(" "%28" ")" "%29" "✈️" "%E2%9C%88%EF%B8%8F"} $target_dir]
            set target_url "https://graph.microsoft.com/v1.0/me/drive/root:/$encoded_dir"
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
            set root_url "https://graph.microsoft.com/v1.0/me/drive/root"
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
    global path_entry remote_entry tree gui_mode
    
    if {$gui_mode} {
        set item_path [$path_entry get]
        set remote_name [$remote_entry get]
    }
    
    if {$item_path eq ""} {
        update_status "Error: Please enter an item path" red
        return
    }
    
    update_status "Fetching ACL for: $item_path" blue
    
    # Clear existing treeview
    clear_treeview
    
    # Get access token
    set access_token [get_access_token $remote_name]
    if {$access_token eq ""} {
        return
    }
    
    update_status "✅ Successfully extracted access token from rclone.conf" green
    
    # Construct the full path if target_dir is specified
    set full_path $item_path
    if {$target_dir ne ""} {
        set full_path "$target_dir/$item_path"
    }
    
    # Get item info - URL encode the path properly for all Unicode characters
    # Use a more direct approach that handles Unicode properly
    set encoded_path ""
    foreach char [split $full_path ""] {
        if {$char eq " "} {
            append encoded_path "%20"
        } elseif {[string is ascii $char]} {
            append encoded_path $char
        } else {
            # For non-ASCII characters, use proper UTF-8 encoding
            set utf8_bytes [encoding convertto utf-8 $char]
            foreach byte [split $utf8_bytes ""] {
                append encoded_path [format "%%%02X" [scan $byte %c]]
            }
        }
    }
    set item_url "https://graph.microsoft.com/v1.0/me/drive/root:/$encoded_path"
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
    
    update_status "✅ Found $item_type: $item_name (ID: $item_id)" green
    
    # Get permissions
    set permissions_url "https://graph.microsoft.com/v1.0/me/drive/items/$item_id/permissions"
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
    
    update_status "✅ Found $perm_count permission(s) in ACL" green
    
    if {$gui_mode} {
        # Populate treeview
        set perm_num 1
        foreach perm $permissions {
            set perm_id [dict get $perm id]
            set roles [dict get $perm roles]
            set roles_str [join $roles ", "]
            
            # Get user information
            set user_name "N/A"
            set user_email "N/A"
            
            if {[dict exists $perm grantedTo user]} {
                set user [dict get $perm grantedTo user]
                set user_name [dict get $user displayName]
                set user_email [dict get $user email]
            } elseif {[dict exists $perm grantedToIdentities]} {
                set identities [dict get $perm grantedToIdentities]
                if {[llength $identities] > 0} {
                    set identity [lindex $identities 0]
                    if {[dict exists $identity user]} {
                        set user [dict get $identity user]
                        set user_name [dict get $user displayName]
                        set user_email [dict get $user email]
                    }
                }
            }
            
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
            if {[lsearch $roles "owner"] >= 0} {
                set tag "owner"
            } elseif {[lsearch $roles "read"] >= 0} {
                set tag "read"
            }
            
            # Insert into treeview
            $tree insert {} end -text "Permission $perm_num" \
                -values [list $perm_id $roles_str $user_name $user_email $link_type $link_scope $expires] \
                -tags $tag
            
            incr perm_num
        }
    } else {
        # Display in CLI mode
        display_acl_cli $permissions $item_id
    }
    
    update_status "✅ ACL listing of: $item_id" green
}

if {$gui_mode} {
    # GUI mode - create interface
    # Bind Enter key to path entry for manual navigation
    bind $path_entry <Return> {
        set path [%W get]
        if {$path ne ""} {
            # Navigate to the typed path
            navigate_to_typed_path $path
        }
    }
    bind $remote_entry <Return> {
        # Refresh folder list when remote changes
        load_folder_contents $current_folder_id $current_folder_path
    }
    
    # Bind folder listbox events
    bind $folder_listbox <Button-1> {
        set selection [%W curselection]
        if {$selection ne ""} {
            set folder_name [%W get $selection]
            navigate_to_folder $folder_name
        }
    }
    bind $folder_listbox <Double-Button-1> {
        set selection [%W curselection]
        if {$selection ne ""} {
            set folder_name [%W get $selection]
            if {$folder_name ne ".."} {
                navigate_to_folder $folder_name
            }
        }
    }
    
    # Set focus to path entry
    focus $path_entry
    
    # Main event loop - handle command line arguments
    set target_dir ""
    if {[info exists argv] && [llength $argv] > 0} {
        set i 0
        while {$i < [llength $argv]} {
            set arg [lindex $argv $i]
            if {$arg eq "--dir" && $i + 1 < [llength $argv]} {
                set target_dir [lindex $argv [expr $i + 1]]
                incr i 2
            } elseif {$arg eq "--remote" && $i + 1 < [llength $argv]} {
                set remote_name [lindex $argv [expr $i + 1]]
                $remote_entry delete 0 end
                $remote_entry insert 0 $remote_name
                incr i 2
            } elseif {[string index $arg 0] ne "-"} {
                set item_path $arg
                $path_entry insert 0 $item_path
                incr i
            } else {
                incr i
            }
        }
    }
    
    update_status "OneDrive ACL Lister - Ready to fetch ACL information" blue
    
    # Initialize with root folder or target directory
    if {$target_dir ne ""} {
        # Navigate to the specified directory
        navigate_to_typed_path $target_dir
    } else {
        # Initialize with root folder
        load_folder_contents "root" ""
    }
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