# encoding: UTF-8

require 'thread'
require 'net/http'
require 'open-uri'
require 'fileutils'
require 'cgi'
require 'json'
require 'nokogiri'
require_relative 'wayback_machine_downloader/tidy_bytes'
require_relative 'wayback_machine_downloader/to_regex'
require_relative 'wayback_machine_downloader/archive_api'

class WaybackMachineDownloader

  include ArchiveAPI

  VERSION = "2.3.2"

  attr_accessor :base_url, :exact_url, :directory, :all_timestamps,
    :from_timestamp, :to_timestamp, :only_filter, :exclude_filter, 
    :all, :maximum_pages, :threads_count, :rewrite_urls

  def initialize params
    @base_url = params[:base_url]
    @exact_url = params[:exact_url]
    @directory = params[:directory]
    @all_timestamps = params[:all_timestamps]
    @from_timestamp = params[:from_timestamp].to_i
    @to_timestamp = params[:to_timestamp].to_i
    @only_filter = params[:only_filter]
    @exclude_filter = params[:exclude_filter]
    @all = params[:all]
    @maximum_pages = params[:maximum_pages] ? params[:maximum_pages].to_i : 100
    @threads_count = params[:threads_count].to_i
    @rewrite_urls = params[:rewrite_urls].nil? ? true : params[:rewrite_urls]  # Default to true
  end

  def backup_name
    if @base_url.include? '//'
      @base_url.split('/')[2]
    else
      @base_url
    end
  end

  def backup_path
    if @directory
      if @directory[-1] == '/'
        @directory
      else
        @directory + '/'
      end
    else
      'websites/' + backup_name + '/'
    end
  end

  def match_only_filter file_url
    if @only_filter
      only_filter_regex = @only_filter.to_regex
      if only_filter_regex
        only_filter_regex =~ file_url
      else
        file_url.downcase.include? @only_filter.downcase
      end
    else
      true
    end
  end

  def match_exclude_filter file_url
    if @exclude_filter
      exclude_filter_regex = @exclude_filter.to_regex
      if exclude_filter_regex
        exclude_filter_regex =~ file_url
      else
        file_url.downcase.include? @exclude_filter.downcase
      end
    else
      false
    end
  end

  def get_all_snapshots_to_consider
    # Note: Passing a page index parameter allow us to get more snapshots,
    # but from a less fresh index
    http = Net::HTTP.new("web.archive.org", 443)
    http.use_ssl = true
    http.start()
    print "Getting snapshot pages"
    snapshot_list_to_consider = []
    snapshot_list_to_consider += get_raw_list_from_api(@base_url, nil, http)
    print "."
    unless @exact_url
      @maximum_pages.times do |page_index|
        snapshot_list = get_raw_list_from_api(@base_url + '/*', page_index, http)
        break if snapshot_list.empty?
        snapshot_list_to_consider += snapshot_list
        print "."
      end
    end
    http.finish()
    puts " found #{snapshot_list_to_consider.length} snaphots to consider."
    puts
    snapshot_list_to_consider
  end

  def get_file_list_curated
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      file_id = file_url.split('/')[3..-1].join('/')
      file_id = CGI::unescape file_id 
      file_id = file_id.tidy_bytes unless file_id == ""
      if file_id.nil?
        puts "Malformed file url, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          puts "File url matches exclude filter, ignoring: #{file_url}"
        elsif not match_only_filter(file_url)
          puts "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id]
          unless file_list_curated[file_id][:timestamp] > file_timestamp
            file_list_curated[file_id] = {file_url: file_url, timestamp: file_timestamp}
          end
        else
          file_list_curated[file_id] = {file_url: file_url, timestamp: file_timestamp}
        end
      end
    end
    file_list_curated
  end

  def get_file_list_all_timestamps
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      file_id = file_url.split('/')[3..-1].join('/')
      file_id_and_timestamp = [file_timestamp, file_id].join('/')
      file_id_and_timestamp = CGI::unescape file_id_and_timestamp 
      file_id_and_timestamp = file_id_and_timestamp.tidy_bytes unless file_id_and_timestamp == ""
      if file_id.nil?
        puts "Malformed file url, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          puts "File url matches exclude filter, ignoring: #{file_url}"
        elsif not match_only_filter(file_url)
          puts "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id_and_timestamp]
          puts "Duplicate file and timestamp combo, ignoring: #{file_id}" if @verbose
        else
          file_list_curated[file_id_and_timestamp] = {file_url: file_url, timestamp: file_timestamp}
        end
      end
    end
    puts "file_list_curated: " + file_list_curated.count.to_s
    file_list_curated
  end


  def get_file_list_by_timestamp
    if @all_timestamps
      file_list_curated = get_file_list_all_timestamps
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    else
      file_list_curated = get_file_list_curated
      file_list_curated = file_list_curated.sort_by { |k,v| v[:timestamp] }.reverse
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    end
  end

  def list_files
    # retrieval produces its own output
    @orig_stdout = $stdout
    $stdout = $stderr
    files = get_file_list_by_timestamp
    $stdout = @orig_stdout
    puts "["
    files[0...-1].each do |file|
      puts file.to_json + ","
    end
    puts files[-1].to_json
    puts "]"
  end

  def download_files
    start_time = Time.now
    puts "Downloading #{@base_url} to #{backup_path} from Wayback Machine archives."
    puts

    if file_list_by_timestamp.count == 0
      puts "No files to download."
      puts "Possible reasons:"
      puts "\t* Site is not in Wayback Machine Archive."
      puts "\t* From timestamp too much in the future." if @from_timestamp and @from_timestamp != 0
      puts "\t* To timestamp too much in the past." if @to_timestamp and @to_timestamp != 0
      puts "\t* Only filter too restrictive (#{only_filter.to_s})" if @only_filter
      puts "\t* Exclude filter too wide (#{exclude_filter.to_s})" if @exclude_filter
      return
    end
 
    puts "#{file_list_by_timestamp.count} files to download:"

    threads = []
    @processed_file_count = 0
    @threads_count = 1 unless @threads_count != 0
    @threads_count.times do
      http = Net::HTTP.new("web.archive.org", 443)
      http.use_ssl = true
      http.start()
      threads << Thread.new do
        until file_queue.empty?
          file_remote_info = file_queue.pop(true) rescue nil
          download_file(file_remote_info, http) if file_remote_info
        end
        http.finish()
      end
    end

    threads.each(&:join)
    end_time = Time.now
    puts
    puts "Download completed in #{(end_time - start_time).round(2)}s, saved in #{backup_path} (#{file_list_by_timestamp.size} files)"
  end

  def structure_dir_path dir_path
    begin
      FileUtils::mkdir_p dir_path unless File.exist? dir_path
    rescue Errno::EEXIST => e
      error_to_string = e.to_s
      puts "# #{error_to_string}"
      if error_to_string.include? "File exists @ dir_s_mkdir - "
        file_already_existing = error_to_string.split("File exists @ dir_s_mkdir - ")[-1]
      elsif error_to_string.include? "File exists - "
        file_already_existing = error_to_string.split("File exists - ")[-1]
      else
        raise "Unhandled directory restructure error # #{error_to_string}"
      end
      file_already_existing_temporary = file_already_existing + '.temp'
      file_already_existing_permanent = file_already_existing + '/index.html'
      FileUtils::mv file_already_existing, file_already_existing_temporary
      FileUtils::mkdir_p file_already_existing
      FileUtils::mv file_already_existing_temporary, file_already_existing_permanent
      puts "#{file_already_existing} -> #{file_already_existing_permanent}"
      structure_dir_path dir_path
    end
  end

  # Modified download_file method with URL rewriting
  def download_file(file_remote_info, http)
    current_encoding = "".encoding
    file_url = file_remote_info[:file_url].encode(current_encoding)
    file_id = file_remote_info[:file_id]
    file_timestamp = file_remote_info[:timestamp]
    file_path_elements = file_id.split('/')
    if file_id == ""
      dir_path = backup_path
      file_path = backup_path + 'index.html'
    elsif file_url[-1] == '/' or not file_path_elements[-1].include? '.'
      dir_path = backup_path + file_path_elements[0..-1].join('/')
      file_path = backup_path + file_path_elements[0..-1].join('/') + '/index.html'
    else
      dir_path = backup_path + file_path_elements[0..-2].join('/')
      file_path = backup_path + file_path_elements[0..-1].join('/')
    end
    if Gem.win_platform?
      dir_path = dir_path.gsub(/[:*?&=<>\\|]/) {|s| '%' + s.ord.to_s(16) }
      file_path = file_path.gsub(/[:*?&=<>\\|]/) {|s| '%' + s.ord.to_s(16) }
    end
    unless File.exist? file_path
      begin
        structure_dir_path dir_path
        open(file_path, "wb") do |file|
          begin
            content = ""
            http.get(URI("https://web.archive.org/web/#{file_timestamp}id_/#{file_url}")) do |body|
              content += body
            end
            
            # Process content to rewrite URLs if enabled and file is HTML or CSS
            if @rewrite_urls && should_rewrite_urls?(file_path)
              content = rewrite_urls_in_content(content, file_path, file_url)
            end
            
            file.write(content)
          rescue OpenURI::HTTPError => e
            puts "#{file_url} # #{e}"
            if @all
              file.write(e.io.read)
              puts "#{file_path} saved anyway."
            end
          rescue StandardError => e
            puts "#{file_url} # #{e}"
          end
        end
      rescue StandardError => e
        puts "#{file_url} # #{e}"
      ensure
        if not @all and File.exist?(file_path) and File.size(file_path) == 0
          File.delete(file_path)
          puts "#{file_path} was empty and was removed."
        end
      end
      semaphore.synchronize do
        @processed_file_count += 1
        puts "#{file_url} -> #{file_path} (#{@processed_file_count}/#{file_list_by_timestamp.size})"
      end
    else
      semaphore.synchronize do
        @processed_file_count += 1
        puts "#{file_url} # #{file_path} already exists. (#{@processed_file_count}/#{file_list_by_timestamp.size})"
      end
    end
  end

  # Determine if we should rewrite URLs in this file based on extension
  def should_rewrite_urls?(file_path)
    extension = File.extname(file_path).downcase
    ['.html', '.htm', '.css', '.js'].include?(extension)
  end
  
  # Rewrite URLs in HTML, CSS and JS content to make them relative
  def rewrite_urls_in_content(content, file_path, original_url)
    extension = File.extname(file_path).downcase
    
    case extension
    when '.html', '.htm'
      rewrite_urls_in_html(content, file_path, original_url)
    when '.css'
      rewrite_urls_in_css(content, file_path, original_url)
    when '.js'
      rewrite_urls_in_js(content, file_path, original_url)
    else
      content # Return unchanged for other file types
    end
  end
  
  # Rewrite URLs in HTML documents
  def rewrite_urls_in_html(content, file_path, original_url)
    begin
      doc = Nokogiri::HTML(content)
      
      # Get the relative path of this file from the backup root
      file_relative_path = file_path.sub(backup_path, '')
      file_directory = File.dirname(file_relative_path)
      
      # Handle links (a href)
      doc.css('a[href]').each do |link|
        href = link['href']
        next if href.nil? || href.empty? || href.start_with?('#') || href.start_with?('javascript:') || href.start_with?('mailto:')
        link['href'] = convert_to_relative_path(href, file_directory)
      end
      
      # Handle images, scripts, links, iframes, etc
      {
        'img' => 'src',
        'script' => 'src',
        'link' => 'href',
        'iframe' => 'src',
        'embed' => 'src',
        'source' => 'src',
        'object' => 'data'
      }.each do |tag, attr|
        doc.css("#{tag}[#{attr}]").each do |element|
          src = element[attr]
          next if src.nil? || src.empty? || src.start_with?('data:') || src.start_with?('javascript:')
          element[attr] = convert_to_relative_path(src.strip, file_directory)
        end
      end
      
      # Handle CSS background images and imports
      doc.css('style').each do |style|
        style.content = rewrite_urls_in_css(style.content, file_path, original_url)
      end
      
      # Handle inline styles
      doc.css('[style]').each do |element|
        element['style'] = rewrite_urls_in_css("{a{#{element['style']}}}", file_path, original_url).gsub(/^a\{|\}$/, '')
      end
      
      # Convert the document back to string
      doc.to_s
    rescue => e
      puts "Error rewriting HTML URLs in #{file_path}: #{e.message}"
      content # Return original content if rewriting failed
    end
  end
  
  # Rewrite URLs in CSS files
  def rewrite_urls_in_css(content, file_path, original_url)
    begin
      file_relative_path = file_path.sub(backup_path, '')
      file_directory = File.dirname(file_relative_path)
      
      # Handle url() and @import rules
      content.gsub(/url\(['"]?([^'")]+)['"]?\)/i) do
        url = $1.strip
        next "url(#{url})" if url.start_with?('data:') # Skip data URLs
        
        relative_url = convert_to_relative_path(url, file_directory)
        "url(#{relative_url})"
      end
    rescue => e
      puts "Error rewriting CSS URLs in #{file_path}: #{e.message}"
      content # Return original content if rewriting failed
    end
  end
  
  # Rewrite URLs in JavaScript (basic approach, may need refinement)
  def rewrite_urls_in_js(content, file_path, original_url)
    # This is a simple approach that may not catch all JS URLs
    # For a more comprehensive solution, a JavaScript parser would be needed
    file_relative_path = file_path.sub(backup_path, '')
    file_directory = File.dirname(file_relative_path)
    
    content.gsub(/(["'])((https?:)?\/\/[^"']+)(["'])/) do
      quote = $1
      url = $2
      closing_quote = $4
      
      if url.include?(backup_name) # Only replace URLs for our domain
        relative_url = convert_to_relative_path(url, file_directory)
        "#{quote}#{relative_url}#{closing_quote}"
      else
        "#{quote}#{url}#{closing_quote}" # Keep external URLs as is
      end
    end
  end
  
  # Convert an absolute URL to a relative path
  def convert_to_relative_path(url, file_directory)
    # Return unchanged if already relative (except for simple /) or external
    return url if (url.start_with?('./') || url.start_with?('../')) && url != '/'
    
    # Handle protocol-relative URLs
    if url.start_with?('//') 
      url = "http:#{url}" # Add protocol for parsing
    end
    
    begin
      uri = URI.parse(url)
      
      # Leave external URLs unchanged
      return url if uri.host && !url_belongs_to_site?(uri.host)
      
      # Extract path from the URL (remove domain, protocol, etc.)
      path = uri.path
      path = '/' if path.nil? || path.empty?
      
      # Clean up path
      path = path.gsub(/^\//, '') # Remove leading slash
      
      # We need to know the file directory relative to the backup root
      # This is to prevent duplicate directory names in paths
      root_directory = backup_path.sub(/\/$/, '')
      if file_directory.start_with?(backup_name)
        # Convert from domain-based path to relative path
        file_directory = file_directory.sub(/^#{backup_name}\//, '')
      end
      
      # Split paths into components
      file_parts = file_directory.split('/')
      target_parts = path.split('/')
      
      # Skip common prefix path components to avoid duplications
      common_prefix_length = 0
      [file_parts.length, target_parts.length].min.times do |i|
        break if file_parts[i] != target_parts[i]
        common_prefix_length = i + 1
      end
      
      # Calculate the number of directories to go up
      up_levels = file_parts.length - common_prefix_length
      
      # Build the relative path
      if up_levels == 0 && common_prefix_length == 0
        # No common prefix and no need to go up
        result_path = "./#{path}"
      else
        # Need to go up some levels
        prefix = up_levels > 0 ? '../' * up_levels : './'
        remaining_path = target_parts[common_prefix_length..-1].join('/')
        result_path = "#{prefix}#{remaining_path}"
      end
      
      # Add query string and fragment if present
      result_path += "?#{uri.query}" if uri.query
      result_path += "##{uri.fragment}" if uri.fragment
      
      result_path
    rescue URI::InvalidURIError => e
      # If we can't parse the URL, return it unchanged
      puts "Warning: Could not parse URL '#{url}': #{e.message}"
      url
    end
  end

  # Check if a URL belongs to the site we're downloading
  def url_belongs_to_site?(host)
    # Extract domain from the base_url for comparison
    base_host = if @base_url.include? '//'
                  @base_url.split('/')[2]
                else
                  @base_url
                end
    
    host == base_host || host.end_with?(".#{base_host}")
  end

  def file_queue
    @file_queue ||= file_list_by_timestamp.each_with_object(Queue.new) { |file_info, q| q << file_info }
  end

  def file_list_by_timestamp
    @file_list_by_timestamp ||= get_file_list_by_timestamp
  end

  def semaphore
    @semaphore ||= Mutex.new
  end
end
