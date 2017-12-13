# coding: utf-8
require "io/console"

require "rubygems"
require "json"
require "httparty"

require "fileutils"
require "zip"

require 'open-uri'

FORMATS = %w(aiff flac mp3 wav)
YESNO = %w(y n)

HR = "\n================================================================================\n"

MAX_TRIES = 10

class DripFM
  include HTTParty
  base_uri "https://drip.kickstarter.com"
  self.ssl_version :SSLv23

  # GETTERS / SETTERS
  # Cookies
  def cookies(); @cookies end
  def cookies=(c); @cookies = c end
  # Current user
  def user(); @user end
  def user=(u); @user = u end
  # Login data
  def login_data(); @login_data end
  def login_data=(ld); @login_data = ld end
  # Releases
  def releases(); @releases end
  def releases=(r); @releases = r end
  # Settings
  def settings(); @settings end
  def settings=(s) @settings = s end

  # HELPERS
  def choose(prompt, choices, options={})
    choices_str = choices.join '/'
    choices_str = options[:choices_str] if options[:choices_str]

    choices_stringified = choices.map { |choice| choice.to_s }

    choice = ""
    while !(choices_stringified.include? choice) do
      print "#{prompt} (#{choices_str}): "
      choice = gets.chomp.downcase
    end

    if options[:boolean]
      return choice == "y"
    else
      return choice
    end
  end

  def send_login_request
    login_req = self.class.post "/api/users/login",
      body: @login_data.to_json,
      :headers => { 'Content-Type' => 'application/json', 'Accept' => 'application/json'}

    response_code = login_req.response.code.to_i

    if response_code < 400
      @cookies = login_req.headers["Set-Cookie"]
      @user = JSON.parse(login_req.body)
    end

    return response_code
  end

  # Safe filename without illegal characters
  def safe_filename(filename)
    out = filename.gsub(/[\x00:\*\?\"<>\|]/, ' ').strip
    out.encode! "US-ASCII", out.encoding, replace: "_"
    out
  end

  def safe_dirname(dirname)
    out = dirname.gsub(/[\x00:\\\/\*\?\"<>\|]/, ' ').strip
    out.encode! "US-ASCII", out.encoding, replace: "_"
    out
  end

  # Label directory name
  def label_dirname_for_release(release)
    dirname = release["creative"]["service_name"]
    dirname = dirname[0..40].strip

    safe_dirname(dirname)
  end

  # Returns the zip file name for a release
  def zip_filename(release)
    if release['slug'] && release['slug'].length > 0
      filename = release['slug'][0..40].strip
    else
      filename = release['id'].to_s
    end
    dirname = label_dirname_for_release(release)

    "#{dirname}/#{safe_filename(filename)}.zip"
  end

  # Returns the unpack directory name for a release
  def unpack_dirname(release)
    artist_dir = safe_dirname release["artist"][0..40].strip
    title_dir = safe_dirname release["title"][0..40].strip
    dirname = label_dirname_for_release(release)

    "#{dirname}/#{artist_dir}/#{title_dir}"
  end

  # The constructor
  def initialize(e, p)
    @settings = {}
    @login_data = { email: e, password: p }

    login_response = send_login_request

    if login_response >= 400
      puts "FAIL: Wrong login data according to drip :("
      abort
    end

    puts "\n\n"
    puts "Login success!"

    # Greet this dawg!
    puts "Hi, #{@user['firstname']} #{@user['lastname']}! :)\n\n"

    # DO THINGS
    @settings = ask_for_settings
    puts HR
    @releases = set_releases

    grab_releases
  end

  # Set the @releases object from all the user's releases.
  def set_releases
    releases = []
    releases_part_index = 1
    releases_part = nil
    user_id = @user['id']

    print "\n"

    while releases_part != []
      print "\rFetching list of releases, page #{releases_part_index}..."
      releases_req = self.class.get "/api/users/#{user_id}/releases?page=#{releases_part_index}",
        headers: { "Cookie" => @cookies }

      releases_part = JSON.parse(releases_req.body)

      releases += releases_part.reject { |r| r["unlocked"] == false }
      releases_part_index += 1
    end

    print "\n"

    releases
  end

  # Ask the user for settings for this run
  def ask_for_settings
    format = choose "Which format do you want to download the releases in?", FORMATS
    puts "\tFLAC is superior, you Apple loving hipster. But I'll grab AIFF for you anyways." if format == "aiff"

    unpack = choose "Do you want to automatically unpack the downloaded releases?", YESNO,
      boolean: true

    { format: format, unpack: unpack }
  end

  # Fetch and save the releases.
  def grab_releases
    puts "Let's see here..."
    puts "Found #{@releases.count} releases that you can download in total before the end times come."
    puts
p
    @releases.each do |release|
      artist = release['artist']
      title = release['title']

      puts "We've got \"#{title}\" by #{artist}."

      dirname = unpack_dirname(release)
      zipfile = zip_filename(release)

      if (File.size?(zipfile) \
        or (
          File.directory?(dirname) \
          and not (
            (Dir.entries(dirname) - %w{ . .. Thumbs.db .DS_Store }).empty?
          )
        )
      )
        puts "It seems you've already got this release. Skipping."
        puts "========"
        puts
      else
        fetch_release(release)
      end
    end
  end

  def fetch_release(release, trycount=0, chosen_format=nil)
    creative_slug = release['creative']['slug']
    release_url = "/api/creatives/#{creative_slug}/releases/#{release['id']}"
    formats = JSON.parse(self.class.get(release_url + "/formats").body)

    chosen_format ||= @settings[:format]
    if !(formats.include? chosen_format)
      puts "[!] This release was not published with your preferred format."
      chosen_format = choose "[!] Please choose an available format", formats
    end

    url = "https://drip.kickstarter.com/api/creatives/#{release['creative_id']}"
    url += "/releases/#{release['id']}"
    url += "/download?release_format=#{chosen_format}"

    # create directory to store the file in, if it doesn't exist (mkdir -p)
    dirname = label_dirname_for_release(release)
    FileUtils.mkdir_p(dirname)
    
    filename = zip_filename(release)

    if trycount <= 0
      puts "Saving to \"#{filename}\", please stand by while this release is being fetched..."
    end

    success = false
    begin
      download = open(url, "Cookie" => @cookies)
    rescue => e
      puts "[!] An error occurred while downloading #{release['title']}: \"#{e.message}\". Retrying."

      fetch_release(release, trycount, chosen_format)
      return
    end

    IO.copy_stream(download, filename)
    unpack_release(release) if @settings[:unpack]

    puts "Done. :)"
    puts "========"
    puts

    if @settings[:unpack]
      FileUtils.rm filename, force: true # remove zip after unpacking or if fetching fails
    end
  end

  def unpack_release(release)
    puts "Unpacking #{release['title']}..."

    filename = zip_filename(release)

    if File.exist? filename
      dirname = unpack_dirname(release)
      FileUtils.mkdir_p(dirname)

      begin
        Zip::File.open(filename) do |zipfile|
          zipfile.each do |file|
            target_filename = safe_filename("#{dirname}/#{file.name}")
            file.extract target_filename
          end
        end
      rescue Zip::Error => e
        puts "[!] Something went wrong while unpacking #{release['title']}: \"#{e.message}\""

        retry_unpack = choose "[!] Wanna retry?", YESNO,
          boolean: true

        if retry_unpack
          unpack_release(release)
        end
      end
    else
      puts "Source zip file could not be found! Release could not be unpacked :("
    end
  end

end

### MAIN CODE
puts "               +----------------------------------------------+"
puts "               | WELCOME TO THE DRIP RAGNARÖK DOWNLOADER 2017 |"
puts "               +----------------------------------------------+"
puts "\n"
puts "                 \"Skeggǫld! Skálmǫld! Skildir ro Klofnir!\""
puts "                   - You, #{Time.now.year}"

puts HR

puts "Please enter your login info!"
print "Email: "
email = gets.chomp
print "Password: "
password = STDIN.noecho(&:gets).chomp

drip = DripFM.new(email, password)

puts "                                   ALL DONE!"
puts "                         Thanks for using this tool <3"
