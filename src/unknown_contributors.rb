#!/usr/bin/env ruby

require 'csv'
require 'pry'
require 'octokit'
require 'json'
require 'concurrent'
require 'unidecoder'
require 'pg'

require './email_code'
require './ghapi'
require './genderize_lib'
require './geousers_lib'

# type,email,name,github,linkedin1,linkedin2,linkedin3,contributions,gender,location,affiliations
gcs = octokit_init()
hint = rate_limit(gcs)[0]
init_sqls()

json = JSON.parse(File.read('github_users.json'))
data = {}
ks = {}
json.each do |row|
  email = row['email']
  row.keys.each { |k| ks[k] = 0 }
  data[email] = [] unless data.key?(email)
  data[email] << row
end

ary = []
new_objs = []
contributions = {}
idx = 0
CSV.foreach('unknown_contributors.csv', headers: true) do |row|
  #rank_number,actor,contributions,percent,cumulative_sum,cumulative_percent,all_contributions
  idx += 1
  ghid = row['actor']
  contributions[ghid] = row['contributions']
  if data.key?(ghid)
    ary << data[ghid]
  else
    puts "#{idx}) Asking GitHub for #{ghid}"
    u = gcs[hint].user ghid
    h = u.to_h
    if h[:location]
      print "Geolocation for #{h[:location]} "
      h[:country_id], h[:tz] = get_cid h[:location]
      puts "-> (#{h[:country_id]}, #{h[:tz]})"
    else
      h[:country_id], h[:tz] = nil, nil
    end
    print "(#{h[:name]}, #{h[:login]}, #{h[:country_id]}) "
    h[:sex], h[:sex_prob], ok = get_sex h[:name], h[:login], h[:country_id]
    puts "-> (#{h[:sex]}, #{h[:sex_prob]})"
    h[:commits] = 0
    h[:affiliation] = "(Unknown)"
    h[:email] = "#{ghid}!users.noreply.github.com"
    h[:source] = "config"
    obj = {}
    ks.keys.each { |k| obj[k.to_s] = h[k.to_sym] }
    new_objs << obj
    ary << obj
  end
end

puts "Writting CSV..."
hdr = %w(type email name github linkedin1 linkedin2 linkedin3 contributions gender location affiliations)
CSV.open('task.csv', 'w', headers: hdr) do |csv|
  csv << hdr
  ary.each do |row|
    login = row['login']
    email = row['email']
    email = "#{login}!users.noreply.github.com" if email.nil?
    name = row['name']
    ary2 = email.split '!'
    uname = ary2[0]
    dom = ary2[1]
    escaped_name = URI.escape(name)
    escaped_uname = URI.escape(name + ' ' + uname)
    lin1 = lin2 = lin3 = ''
    if !dom.nil? && dom.length > 0 && dom != 'users.noreply.github.com'
      ary3 = dom.split '.'
      domain = ary3[0]
      escaped_domain = URI.escape(name + ' ' + domain)
      lin1 = "https://www.linkedin.com/search/results/index/?keywords=#{escaped_name}"
      lin2 = "https://www.linkedin.com/search/results/index/?keywords=#{escaped_uname}"
      lin3 = "https://www.linkedin.com/search/results/index/?keywords=#{escaped_domain}"
    else
      lin1 = "https://www.linkedin.com/search/results/index/?keywords=#{escaped_name}"
      lin2 = "https://www.linkedin.com/search/results/index/?keywords=#{escaped_uname}"
    end
    loc = ''
    loc += row['location'] unless row['location'].nil?
    loc += ' ' + row['country_id'] unless row['country_id'].nil?
    csv << ['(Unknown)', email, name, lin1, lin2, lin3, contributions[login], row['sex'], loc, '']
  end
end

puts "Writting JSON..."
new_objs.each do |row|
  json << row
end
json_data = email_encode(JSON.pretty_generate(json))
File.write 'github_users.json', json_data