module TourpaqAuth
  # A small thread-safe cache with expiry, used when the app has no Rails.cache. It speaks the subset of
  # the ActiveSupport::Cache::Store interface the gem uses: read, write(expires_in:), delete, clear.
  class MemoryStore
    def initialize
      @data = {}
      @mutex = Mutex.new
    end

    def read(key)
      @mutex.synchronize do
        value, expires_at = @data[key]
        return nil unless @data.key?(key)
        if expires_at && expires_at <= TourpaqAuth.now
          @data.delete(key)
          return nil
        end
        value
      end
    end

    def write(key, value, expires_in: nil)
      @mutex.synchronize do
        @data[key] = [ value, expires_in ? TourpaqAuth.now + expires_in.to_f : nil ]
      end
      true
    end

    def delete(key)
      @mutex.synchronize { !@data.delete(key).nil? }
    end

    def clear
      @mutex.synchronize { @data.clear }
    end
  end
end
