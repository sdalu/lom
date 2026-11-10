require 'bundler'
require 'yard'
require 'rake/testtask'

Bundler::GemHelper.install_tasks

YARD::Rake::YardocTask.new do |t|
    t.files         = [ 'lib/**/*.rb' ]
    t.options       = [ '-m', 'markdown' ]
    t.stats_options = [ '--list-undoc' ]
end

Rake::TestTask.new do |t|
    t.libs       << 'lib'
    t.test_files  = FileList['test/**/*_test.rb']
end
