# Add any specified users and groups
class local_users::add (
  # Class parameters are populated from module hiera data
  String $root_home_dir,
  String $user_home_location,
  Boolean $purge_ssh_keys,
  Boolean $group_auth_membership,
  Boolean $system_group,
  String $user_group_membership,
  # Force the fixing of the GID to match UID when a group is based on the users name
  Boolean $force_group_gid_fix,
  # Whether to modify the permissions of the files in the user's home directory
  Boolean $fix_user_perms,
) {

  include stdlib

  # Set up the defaults for the group resource creation
  $grp_defaults = {
    ensure          => present,
    #allowdupe      => true,
    system          => $system_group,
    auth_membership => $group_auth_membership,
    forcelocal      => $local_users::forcelocal,
  }

  # Set up the defaults for the user resource creation
  $usr_defaults = {
    ensure         => present,
    purge_ssh_keys => $purge_ssh_keys,
    managehome     => $local_users::managehome,
    forcelocal     => $local_users::forcelocal,
    membership     => $user_group_membership,
  }

  # Do group actions first
  $groups_lookup = $local_users::groups_to_add
  $groups = $groups_lookup ? {
    Array   => merge({}, {}, *flatten($groups_lookup)),
    default => $groups_lookup
  }

  $groups.each | $group, $props | {
    create_resources( group, { $group => $props }, $grp_defaults )
  }

  # For AIX, get prgp  for all local users
  if $facts['osfamily'] == 'AIX' {
        $users_pgrp = $facts['user_group']
  }
  # Then perform actions on users
  $users_lookup = $local_users::users_to_add
  $users_keys = $local_users::users_keys

  $users = $users_lookup ? {
    Array   => merge({}, {}, *flatten($users_lookup)),
    default => $users_lookup
  }

  $users.each | $name, $props | {
    #notify { "Checking user: $user ($props)": }

    if $props[generate] {
      $generate = $props[generate]
    } else {
      $generate = 1
    }

    # Make sure we have the UID - root's can be guessed
    if $props[uid] {
      $uid = $props[uid]
    }
    else {
      if $name == 'root' {
        $uid = 0
      }
      else {
        #let system decide
      }
    }

    # Make sure we have the GID - use the UID if not specified
    if $props[gid] {
      $gid = $props[gid]
    }
    else {
      if defined( '$uid' ) {
          $gid = $uid
      }
    }

    # Make sure we have the home directory - root's can be guessed
    if $props[base_dir] {
      $base_dir = $props[base_dir]
      $home = "${$base_dir}/${name}"
    }
    elsif $props[home] {
      $home = $props[home]
    }
    else {
      if $name == 'root' {
          $home = $root_home_dir
      }
      else {
          $home = "${user_home_location}/${name}"
      }
    }
    # Find the mode of the home directory
    if $props[mode] {
      $mode = $props[mode]
    }
    else {
      $mode = '0750'
    }

    # Make sure we have a decent GECOS - root's can be guessed
    if $props[comment] {
      $comment = $props[comment]
    }
    else {
      if $name == 'root' {
        $comment = $name
      }
      else {
        fail( "The GECOS of user ${name} must be specified" )
      }
    }

    $groups = $props[groups]

    # Work around some platform idiosychronies
    case $facts['os']['family'] {
      'Suse': {
            if $facts[operatingsystem] == 'SLES' and ($facts[operatingsystemmajrelease]+0) < 12 {
              $expiry_param = '9999-12-31'
            }
            $groups_param = $groups
            $password_max_age = '99999'
      }
      'AIX':  {
            $expiry_param = 'absent'
#           $groups_param = $groups << $name # Add the primary group as well - required for AIX
            # Need to obtain the primary group of the user
            $pgrp = $users_pgrp[$name]
            if $pgrp {
              if !empty( $groups ) {
                $groups_param = $groups << $pgrp # Add the primary group existing groups - required for AIX
              }
              else {
                $groups_param = $pgrp # Add the primary to groups - required for AIX
              }
            }
            else {
                # Avoid Puppet taking blank as undef  in mkuser command 
                $groups_param = $groups
            }
            $password_max_age = '0'
      }
      default:{
            $expiry_param = 'absent'
            $groups_param = $groups
            $password_max_age = '99999'
      }
    }


    # Merge our optimisations with the raw hiera data
    $merged_props = merge( $props,  { home    => $home,
                                      comment => $comment,
                                    } )

    # Add exprity parameters - if required
    if $props[expiry] == 'none' {
      $merged_props2 = merge( $merged_props,  { expiry           => $expiry_param,
                                                password_max_age => $password_max_age,
                                              } )
    }
    else {
      $merged_props2 = $merged_props
    }

    # Add in additional groups - if required
    if $props[groups] {
      $merged_props3 = merge( $merged_props2, { groups => $groups_param } )
    }
    else {
      $merged_props3 = $merged_props2
    }

    # Delete keys not understood by the user resource
    $clean_props = delete( $merged_props3, ['auth_keys','mode','generate','base_dir'] )

    if $generate > 0 {

      if $generate > 1 {
        # Look for the last digits of the username - assumes there is a non digit in the username somewhere
        # the range function from stdlib will generate the list of usernames - this will use
        # a leading zero as a number placeholder - e.g. user09, user10
        # We will zero pad according to the number of digits specified in the username
        $base_user = $name ? {
          /^([^0-9]+)(\d+)$/ => $1,
          /^([^0-9]+)$/      => $1,
          default            => '',
        }
        $base_num = $name ? {
          /^([^0-9]+)(\d+)$/ => $2,
          /^(\d+)$/          => $1,
          default            => '0',
        }
        # Need to resort to ERB as stdlib size function complains about the data type and the length function
        # says it's not found even though it was added in a much earlier version of stdlib
        #$num_length = size( "${base_num}" )
        $num_length = inline_template('<%= @base_num.length %>')
        $last_num = sprintf( "%0${num_length}d", $base_num + $generate - 1 )
        $last_user = "${base_user}${last_num}"
        $range_of_users = range( $base_num, $last_num )
        $array_of_users = $range_of_users.map | $number | {
          { base_user => $base_user, old_num => $base_num, new_num => sprintf( "%0${num_length}d", $number ) }
        }

      } else {
        $array_of_users = [ { user => $name } ]
      }

      if $array_of_users =~ Array {
        $array_of_users.each | $index, $hash | {
          # Find the correct home directory location
          if $generate > 1 {
            $base_user = $hash[base_user]
            $old_num = $hash[old_num]
            $new_num = $hash[new_num]
            $user = "${base_user}${new_num}"
            if $base_dir {
              $user_home = "${$base_dir}/${user}"
            } else {
              $home_arr = split( $home, /\// )
              $home_arr2 = $home_arr - $name + $user
              $user_home = join( $home_arr2, '/' )
            }
            $gecos_arr = split( $props[comment], /\s+/ )
            $gecos_arr2 = $gecos_arr - $old_num + $new_num
            $gecos = join( $gecos_arr2, ' ' )
          } else {
            $user = $hash[user]
            $user_home = $home
            $gecos = $props[comment]
          }

          # If a password is being specified, make it the Sensitive data type to exclude from puppetdb reports
          if 'password' in $clean_props {
            $secure_override = {'password' => Sensitive($clean_props['password'])}
          } else {
            $secure_override = {}
          }

          # If a UID is specified, supply GID also
          if defined( '$uid' ) {
            # Merge our optimisations with the raw hiera data
            $new_uid = $uid + $index
            $user_props = merge( $clean_props,  { uid => $new_uid,
                                                  gid => $gid,
                                                  home => $user_home,
                                                  comment => $gecos,
                                                },
                                                $secure_override,
                                                )
            if $fix_user_perms {
              # Fix the permissions of the user's file in their home directory if the user already exists and their UID is changing
              exec { "chown ${user}":
                path    => '/usr/bin:/usr/sbin:/bin:/sbin',
                onlyif  => "id ${user} && perl -e '\$u = getpwnam(\"${user}\"); if( \$u and \$u ne ${new_uid} ){ exit 0} else { exit 1 }'",
                command => "find ${user_home} -user $(perl -e '\$u = getpwnam(\"${user}\"); print \$u') \
                            | xargs chown ${new_uid} 2>/dev/null || echo ok",
                before  => User[$user],
              }
            }

            # We need to force $gid to string to perform regex even though PDK complains
            if String($gid) =~ /^\d+$/ {
              # Make sure the specified gid exists - must use exec as group resource only manages by name
              # Perhaps this should be converted to a resource to provide better reporting of what wants to happen (or has happened)
              # We only want to do this if the GID has been specified as numeric - if it is text then
              # we assume it already exists
              #create_resources( group, { $name => { gid => $gid} }, $grp_defaults )
              if $facts['osfamily'] == 'AIX' {
                $groupadd_cmd="mkgroup id=${gid} ${user}"
              }
              else {
                if $force_group_gid_fix {
                  # We try to add the group - but if it exists we need to manually edit the group file with the new gid
                  $groupadd_cmd="groupadd --gid ${gid} ${user} 2>/dev/null || \
                                 perl -pe 's/^(${user}):(.*):\\d+:/\$1:\$2:${gid}:/' -i /etc/group"
                } else {
                  # We try to add the group
                  $groupadd_cmd="groupadd --gid ${gid} ${user}"
                }
              }

              exec { "group ${user}":
                path    => '/usr/bin:/usr/sbin:/bin:/sbin',
                unless  => "/bin/grep -c :${gid}: /etc/group",
                command => $groupadd_cmd,
                before  => User[$user],
              }
              $chgrp_before = Exec["group ${user}"]
            }
            else {
              $chgrp_before = undef
            }

            if $fix_user_perms {
              # Also, need to fix the permissions of the files in the home directory if we are changing the GID
              # Only perform this before the group GID has been fixed - otherwise we can't find out the old GID
              # The test needs to check if the user exists and that the GID exists, but is different to what is intended
              # We perform a find for files matching the old GID.  (we don't care if xargs fails, as it will generally mean
              # there are no matching files)
              exec { "chgrp ${user}":
                path    => '/usr/bin:/usr/sbin:/bin:/sbin',
                onlyif  => "id ${user} && perl -e '\
                            @g = getpwnam(\"${user}\"); \
                            if( @g and \$g[3] ne (\"${gid}\" =~ /^\\d+\$/ ? \"${gid}\" : scalar getgrnam(\"${gid}\")) )\
                            { exit 0} else { exit 1 }'",
                command => "find ${user_home} -group $(perl -e '@g = getpwnam(\"${user}\"); print \$g[3]') \
                            | xargs chgrp ${gid} 2>/dev/null || echo ok",
                before  => $chgrp_before,
              }
            }

            create_resources( user, { $user => $user_props }, $usr_defaults )
            $owner_perm = ($uid + $index)
            $group_perm = $gid
          }
          # If the UID is not specified, let the system decide
          else {
            $user_props = merge( $clean_props,  { home => $user_home,
                                                  comment => $gecos,
                                                },
                                                $secure_override,
                                                )
            create_resources( user, { $user => $user_props }, $usr_defaults )
            $owner_perm = $user
            $group_perm = $user
          }

          if  ( $user_props[managehome] != undef and $user_props[managehome] ) or
              ( $user_props[managehome] == undef and $local_users::managehome ) {
            # Make sure each user has a home directory
            file { "${user}home":
              ensure  => directory,
              path    => $user_home,
              owner   => $owner_perm,
              group   => $group_perm,
              seluser => 'system_u',
              mode    => $mode,
              require => User[$user],
            }

            # Add the specified SSH keys to the account
            $keys = $props[auth_keys]
            if $keys =~ Array {
              $keys.each | $key | {
                #notify { "Checking authorized keys for $user: $key": }
                $users_keys.each | $user_key | {
                  $comment = $user_key[comment]
                  #notify { "Checking authorized keys for $user: $key ($comment)": }
                  if $comment == $key {
                    #notify { "Found authorized keys for $user: $key": }
                    $sak1 = {
                      user    => $user,
                      type    => $user_key['type'],
                      key     => $user_key['key'],
                      require => File["${user}home"],
                    }
                    if $user_key['target'] {
                      $sak2 = merge( $sak1, { target =>  $user_key['target'] } )
                    }
                    else {
                      $sak2 = $sak1
                    }
                    if $user_key['options'] {
                      $sak3 = merge( $sak2, { options =>  $user_key['options'] } )
                    }
                    else {
                      $sak3 = $sak2
                    }
                    create_resources( ssh_authorized_key, { "${comment} for ${user}" => $sak3 }, {} )
                  }
                }
              }
            }
          }
        }
      }
    }
  }

}
