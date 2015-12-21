# Copyright 2015 Ooyala, Inc. All rights reserved.
#
# This file is licensed under the MIT License (the "License");
# you may not use this file except in compliance with the
# License. You may obtain a copy of the License at
# http://opensource.org/licenses/MIT
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.  See the License for the specific language governing
# permissions and limitations under the License.

require 'zlib'
require 'fileutils'
require 'rubygems/package'

def whyrun_supported?
  true
end

use_inline_resources

def t_open(tarfile)
  begin
    tarball = ::File.open(tarfile, 'rb')
  rescue StandardError => e
    Chef::Log.warn e.message
    raise e
  end
  begin
    tarball_gz = Zlib::GzipReader.new(tarball)
  rescue Zlib::GzipFile::Error
    # Not gzipped
    tarball = t_rewind(tarball)
  end
  tarball_gz || tarball
end

def t_read(tarball)
  Gem::Package::TarReader.new(tarball)
end

def t_rewind(tarball)
  tarball.rewind
  tarball
end

def mkdir(destination, owner = nil, group = nil, mode = nil)
  directory destination do
    action :create
    owner owner unless owner.nil?
    group group unless group.nil?
    mode mode unless mode.nil?
    recursive true
  end
end

def mkdestdir(tarball_resource)
  dest = ::File.join(tarball_resource.destination, ::File::SEPARATOR)
  return if dest.empty? || ::File.directory?(dest)
  owner = tarball_resource.owner
  group = tarball_resource.group
  # We use octal here for UNIX file mode readability, but we could just
  # as easily have used decimal 511 and gotten the correct behavior
  mode = 0777 & ~tarball_resource.umask.to_i
  mkdir(dest, owner, group, mode)
  tarball_resource.updated_by_last_action(true)
end

def t_mkdir(tarball_resource, entry, pax)
  pax_handler(pax)
  dir = get_tar_entry_path(tarball_resource, entry.full_name)
  return if dir.empty?
  dir = ::File.join(tarball_resource.destination, dir, ::File::SEPARATOR)
  return if ::File.directory?(dir)
  owner = tarball_resource.owner || entry.header.uid
  group = tarball_resource.group || entry.header.gid
  mode = tarball_resource.mode || lambda do
    (fix_mode(entry.header.mode) | 0111) & ~tarball_resource.umask.to_i
  end.call
  mkdir(dir, owner, group, mode)
  tarball_resource.files[:created][:directories] << dir
  tarball_resource.updated_by_last_action(true)
end

# Placeholder method in case someone actually needs PAX support
def pax_handler(pax)
  Chef::Log.debug("PAX: #{pax}") if pax
end

def get_link_target(tarball_resource, entry, type)
  if type == :symbolic
    entry.header.linkname
  else
    target = get_tar_entry_path(tarball_resource, entry.header.linkname)
    ::File.join(tarball_resource.destination, target)
  end
end

def get_tar_entry_path(tarball_resource, full_path)
  if tarball_resource.strip_components
    paths = Pathname.new(full_path)
            .each_filename
            .drop(tarball_resource.strip_components)
    full_path = ::File.join(paths)
  end
  full_path
end

def t_link(tarball_resource, entry, type, pax, longname)
  pax_handler(pax)
  target = get_link_target(tarball_resource, entry, type)

  if type == :hard &&
     !(::File.exist?(target) ||
     tarball_resource.files[:created][:files].include?(target))
    Chef::Log.debug "Skipping #{entry.full_name}: #{target} not found"
    return
  end

  filename = longname || entry.full_name
  src = get_tar_entry_path(tarball_resource, filename)
  return if src.empty?
  src = ::File.join(tarball_resource.destination, src)
  link src do
    to target
    owner tarball_resource.owner || entry.header.uid
    link_type type
    action :create
  end
  tarball_resource.files[:created][:links] << src
  tarball_resource.updated_by_last_action(true)
end

def t_file(tarball_resource, entry, pax, longname)
  pax_handler(pax)
  fqpn = longname || entry.full_name
  fqpn = get_tar_entry_path(tarball_resource, fqpn)
  return if fqpn.empty?
  fqpn = ::File.join(tarball_resource.destination, fqpn)
  Chef::Log.info "Creating file #{fqpn}"
  file fqpn do
    action :create
    owner tarball_resource.owner || entry.header.uid
    group tarball_resource.group || entry.header.gid
    mode tarball_resource.mode ||
      fix_mode(entry.header.mode) & ~tarball_resource.umask.to_i
    sensitive true
    content entry.read
  end
  tarball_resource.files[:created][:files] << fqpn
  tarball_resource.updated_by_last_action(true)
end

def exclude?(filename, tarball_resource)
  Array(tarball_resource.exclude).each do |r|
    return true if ::File.fnmatch?(r, filename)
  end
  false
end

def on_list?(filename, tarball_resource)
  Array(tarball_resource.extract_list).each do |r|
    return true if ::File.fnmatch?(r, filename)
  end
  false
end

def wanted?(filename, tarball_resource, type)
  if ::File.exist?(::File.join(tarball_resource.destination, filename)) &&
     tarball_resource.overwrite == false
    false
  elsif %w(2 L).include?(type)
    true
  else
    tarball_resource.files[:filtered].include?(filename)
  end
end

def t_list(tarball, tarball_resource)
  tarball.each do |entry|
    f = entry.full_name
    next if f.include?('PaxHeader')
    tarball_resource.files[:all] << f
    next unless on_list?(f, tarball_resource) &&
                !exclude?(f, tarball_resource)
    paths = []
    Pathname(f).ascend { |e| paths << e.to_s }
    paths.map! do |p|
      if paths.first.eql?(p)
        p
      else
        p + ::File::SEPARATOR
      end
    end
    tarball_resource.files[:filtered] += paths
  end
  %i(all filtered).each do |type|
    tarball_resource.files[type] = tarball_resource.files[type].uniq
  end
end

def t_extraction(tarball, tarball_resource)
  # pax and longname track extended types that span more than one tar entry
  pax = nil
  longname = nil
  tarball.each do |entry|
    unless wanted?(entry.full_name, tarball_resource, entry.header.typeflag)
      next
    end
    Chef::Log.info "Next tar entry: #{entry.full_name}"
    case entry.header.typeflag
    when '1'
      t_link(tarball_resource, entry, :hard, pax, longname)
      pax = nil
      longname = nil
    when '2'
      t_link(tarball_resource, entry, :symbolic, pax, longname)
      pax = nil
      longname = nil
    when '5'
      t_mkdir(tarball_resource, entry, pax)
      pax = nil
      longname = nil
    when '3', '4', '6', '7'
      Chef::Log.debug "Can't handle type for #{entry.full_name}: skipping"
      pax = nil
      longname = nil
    when 'x', 'g'
      Chef::Log.debug 'PaxHeader'
      pax = entry
      longname = nil
    when 'L', 'K'
      longname = entry.read.strip
      Chef::Log.debug "Using LONG(NAME|LINK) #{longname}"
      pax = nil
    else
      t_file(tarball_resource, entry, pax, longname)
      pax = nil
      longname = nil
    end
  end
end

def fix_mode(mode)
  # GNU tar doesn't store the mode POSIX style, so we fix it
  mode > 07777.to_i ? mode.to_s(8).slice(-4, 4).to_i(8) : mode
end
  require 'pry'

def init_files(new_resource)
  new_resource.files[:all] = []
  new_resource.files[:filtered] = []
  new_resource.files[:created] = {}
  new_resource.files[:created][:files] = []
  new_resource.files[:created][:links] = []
  new_resource.files[:created][:directories] = []
  new_resource
end

def do_tarball(resource_action)
  @new_resource = init_files(@new_resource)
  Chef::Log.info "TARFILE: #{new_resource.source || new_resource.name}"
  tarball = t_open(new_resource.source || new_resource.name)
  tarball = t_rewind(tarball)
  tarball = t_read(tarball)
  t_list(tarball, new_resource)
  if resource_action.eql?(:extract)
    tarball = t_rewind(tarball)
    mkdestdir(new_resource)
    t_extraction(tarball, new_resource)
    new_resource.updated_by_last_action(true)
  end
  tarball.close
  created_files = new_resource.files[:created]
  new_resource.files[:created][:all] = created_files[:files] +
                                       created_files[:links] +
                                       created_files[:directories]
end

provides :tarball if self.respond_to?('provides')

action :extract do
  do_tarball(:extract)
end

action :list do
  do_tarball(:list)
end
