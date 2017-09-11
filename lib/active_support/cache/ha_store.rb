#
# Copyright (C) 2017 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

Bundler.require 'redis'

class ActiveSupport::Cache::HaStore < ActiveSupport::Cache::RedisStore
  def initialize(*)
    super
    options[:lock_timeout] ||= 5
    @delif = Redis::Scripting::Script.new(File.expand_path("../delif.lua", __FILE__))
  end

  protected

  def handle_expired_entry(entry, key, options)
    return super unless options[:race_condition_ttl]
    lock_key = "lock:#{key}"

    unless entry
      while !entry
        unless (lock_nonce = lock(lock_key, options))
          # someone else is already generating it; wait for them
          sleep 0.1
          entry = read_entry(key, options)
          next
        else
          options[:lock_nonce] = lock_nonce
          return nil
        end
      end
      entry
    else
      if entry.expired? && (lock_nonce = lock(lock_key, options))
        options[:lock_nonce] = lock_nonce
        return nil
      end
      # just return the stale value; someone else is busy
      # regenerating it
      entry
    end
  end

  def save_block_result_to_cache(name, options)
    super
  ensure
    if options[:race_condition_ttl]
      key = normalize_key(name, options)
      unlock("lock:#{key}", options[:lock_nonce])
    end
  end

  def lock(key, options)
    nonce = SecureRandom.hex(20)
    nonce if data.set(key, nonce, raw: true, px: (options[:lock_timeout] * 1000).to_i, nx: true)
  end

  def unlock(key, nonce)
    raise ArgumentError("nonce can't be nil") unless nonce
    node = data
    node = data.node_for(key) if data.is_a?(Redis::DistributedStore)
    @delif.run(node, [key], [nonce])
  end
end
