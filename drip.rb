require "io/console"

require "rubygems"
require "json"
require "httparty"

require "fileutils"
require "zip"

AVAILABLE_FORMATS = %w(aiff flac mp3 wav)
CHOICES = %w(y n)
HR = "================================================================================"

class DripFM
  include HTTParty
  base_uri "https://drip.fm"

  # Cookies
  def cookies
    @cookies
  end
  def cookies=(c)
    @cookies = c
  end

  # Current user
  def user
    @user
  end
  def user=(u)
    @user = u
  end

  # Login data
  def login_data
    @login_data
  end
  def login_data=(ld)
    @login_data = ld
  end

  # Chosen label
  def label
    @label
  end
  def label=(l)
    @label = l
  end

  # Releases
  def releases
    @releases
  end
  def releases=(r)
    @releases = r
  end

  # Settings
  def settings
    @settings
  end
  def settings=(s)
    @settings = s
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

    ask_for_settings
    choose_label
    grab_releases
  end

  # Ask the user for settings for this run
  def ask_for_settings
    format = ""
    while !(AVAILABLE_FORMATS.include? format) do
      print "Which format do you want to download the releases in? (aiff/flac/mp3/wav): "
      format = gets.chomp.downcase
    end

    puts "\tFLAC is superior, you Apple loving hipster. But I'll grab AIFF for you anyways." if format == "aiff"

    choice = ""
    while !(CHOICES.include? choice) do
      print "Do you want to automatically unpack the downloaded releases? (y/n): "
      choice = gets.chomp.downcase
    end

    @settings = { format: format, unpack: (choice == "y") }

    puts "\n"
    puts HR
    puts "\n"

  end

  # Ask the user to choose a label
  def choose_label
    labels = @user["memberships"]

    puts "Your subscriptions are:"
    labels.each_index do |i|
      puts "   #{i+1}) #{labels[i]['creative']['service_name']}"
    end

    choices = 1..(labels.length); choice = ""
    while !(choices.include? choice)
      print "\nFrom which one do you wanna grab some sick music? (choose by number): "
      choice = gets.chomp.to_i
    end

    @label = labels[choice-1]
    puts "\n"
    puts HR
    puts "\n"
    puts "Alright, we're gonna fetch some sick shit from #{@label["creative"]["service_name"]}!"

    slug = @label["creative"]["slug"]

    releases_req = self.class.get "/api/creatives/#{slug}/releases",
      headers: { "Cookie" => @cookies }

    @releases = JSON.parse(releases_req.body)
    @releases.reject! { |r| !r["unlocked"] }
  end

  def grab_releases
    puts "\nLet's see here...\n"

    @releases.each do |release|
      puts "We've got \"#{release['title']}\" by #{release['artist']}."
      
      choice = ""
      while !(CHOICES.include? choice) do
        print "Wanna grab that? (y/n) "
        choice = gets.chomp.downcase
      end

      if choice == "y"
        fetch_release(release)
      end
    end
  end

  def fetch_release(release)
    release_url = "/api/creatives/#{@label['creative']['slug']}/releases/#{release['slug']}"
    formats = JSON.parse(self.class.get(release_url + "/formats").body)

    current_format = @settings[:format]

    puts "\tThis release was not published with your preferred format." if !(formats.include? current_format)
    while !(formats.include? current_format)
      print "\tPlease choose an available format (#{formats.join('/')}): "
      current_format = gets.chomp
    end

    url = "/api/users/#{@user['id']}"
    url += "/memberships/#{@label['id']}"
    url += "/download_release?release_id=#{release['id']}"
    url += "&release_format=#{current_format}"

    filename = release['slug'][0..40] + ".zip"

    puts "Saving to \"#{filename}\"..."
    puts "Please stand by while this release is fetched. If your internet sucks ass, just make some tea and wait."

    File.open(filename, "wb") do |f|
      file_request = self.class.get url,
        headers: { "Cookie" => @cookies }

      if file_request.code.to_i < 400
        f.write file_request.parsed_response
        unpack_release(release) if @settings[:unpack]
        puts "Done. :)"
        puts "========"
        puts "\n"
      else
        puts "\tRelease could not be fetched. I'm terribly sorry :("

        choice = ""
        while !(CHOICES.include? choice) do
          print "Wanna retry? (y/n) "
          choice = gets.chomp.downcase
        end

        if(choice == "y")
          send_login_request
          fetch_release(release)
        end
      end
    end

    FileUtils.rm filename, force: true if @settings[:unpack] # remove after unpacking
  end

  def unpack_release(release)
    puts "Unpacking #{release['title']}..."

    filename = release['slug'][0..40] + ".zip"
    artist = release["artist"]
    title = release["title"]

    dirname = "#{artist}/#{title}"
    FileUtils.mkdir_p(dirname)

    Zip::File.open(filename) do |zipfile|
      zipfile.each do |file|
        file.extract "#{dirname}/#{file.name}"
      end
    end
  end

end

### MAIN CODE
puts "\t\t    +-------------------------------------+"
puts "\t\t    | WELCOME TO THE DRIP DOWNLOADER 2014 |"
puts "\t\t    +-------------------------------------+"
puts "\n"
puts "       \"Man this is awesome, I can feel the releases raining down on me\""
puts "           - You, #{Time.now.year}"
puts "\n"
puts HR
puts "\n"

puts "Please enter your login info!"
print "Email: "
email = gets.chomp
print "Password: "
password = STDIN.noecho(&:gets).chomp

drip = DripFM.new(email, password)