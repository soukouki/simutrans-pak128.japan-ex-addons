#!/usr/bin/env ruby

HELP_MESSAGE = <<~EOS
ruby scripts/make.rb <command>

COMMAND:
all: paksetを作成 create pakset
makedat: datファイルを作成 create dat files
makeobj: pakファイルを作成 create pak files
maketab: ja.tab, en.tabを作成 create ja.tab and en.tab
copy: 必要なファイルをコピー copy necessary files
version: バージョン情報を作成 create version information
clean: 作成したファイルを削除 clean up created files
help: このヘルプを表示 display this help
EOS

PAK_DIRS = {
  64 => %w[
    gui64-test
    menu
    symbol
  ],
  128 => %w[
    cursor
    goods
    ground
    ways/128britain-ex
    misc
  ],
  256 => %w[
    ways/iss
    pier/iss
  ],
}

PAK_DIRS_HASH = PAK_DIRS.map{|size, dirs| dirs.map{|dir| [dir, size]} }.flatten(1).to_h

THREAD_COUNT = 6 # GitHub ActionsのThread数が4らしいので、おまけして6スレッドにした

VERSION = ENV['VERSION'] || 'dev'

require 'fileutils'

require_relative 'makedat'
require_relative 'makeobj'

class Make
  def run(args)
    loop do
      case args.shift
      when 'all'
        all()
      when 'makedat'
        makedat()
      when 'makeobj'
        makeobj()
      when 'tab'
        maketab()
      when 'copy'
        copy()
      when 'version'
        version()
      when 'clean'
        clean()
      when 'help', nil
        help()
      else
        puts "Unknown command: #{args.first}"
        help
        break
      end
      break if args.empty?
    end
  end

  def help
    puts HELP_MESSAGE
  end

  def all
    makedat()
    makeobj()
    maketab()
    copy()
    version()
  end

  # makedatを実行
  def makedat
    makedat = MakeDat.new
    Dir.glob('**/*.datt').each do |file|
      dat_file = file.sub(/\.datt$/, '.dat')
      jatab_file = file.sub(/\.datt$/, '.jatab')
      entab_file = file.sub(/\.datt$/, '.entab')
      # 依存ファイルを取得し、datファイルよりも新しいものがあれば再生成する
      dependencies = makedat_dependencies(file)
      dat_mtime = File.exist?(dat_file) ? File.mtime(dat_file) : Time.at(0) # datファイルが存在しない場合は1970年1月1日を基準とする
      jatab_mtime = File.exist?(jatab_file) ? File.mtime(jatab_file) : Time.at(0)
      entab_mtime = File.exist?(entab_file) ? File.mtime(entab_file) : Time.at(0)
      oldest_mtime = [dat_mtime, jatab_mtime, entab_mtime].min
      next if dependencies.all? { |dep| File.exist?(dep) && File.mtime(dep) <= oldest_mtime }
      puts "create_dat: #{file}"
      makedat.create_dat(file)
    end
  end

  # datファイルの依存関係を取得する
  # %requireや%require_excelで指定されたファイルを再帰的に取得する
  def makedat_dependencies(datt_file)
    dependencies = [datt_file]
    File.open(datt_file, 'r') do |file|
      file.each_line do |line|
        if line =~ /^%require\s+['"](.*)['"]/
          require_file = File.expand_path($1, File.dirname(datt_file))
          dependencies += makedat_dependencies(require_file)
        elsif line =~ /^%require_excel\s+['"](.*)['"]/
          require_file = File.expand_path($1, File.dirname(datt_file))
          dependencies << require_file
        end
      end
    end
    dependencies.uniq
  end

  # makeobjを実行
  # 出力はPak128.Japan-Ex+Addons/以下に作成する
  def makeobj
    makeobj = Makeobj.new
    FileUtils.mkdir_p('Pak128.Japan-Ex+Addons')
    # 並列処理のためのキューを作成
    queue = Queue.new
    PAK_DIRS_HASH.each do |dir, size|
      Dir.glob("#{dir}/**/*.dat").each do |file|
        pak_file = 'Pak128.Japan-Ex+Addons/' + File.basename(file, '.dat') + '.pak'
        # pakファイルが存在しない、またはdatファイルよりも新しい場合のみ処理する
        dependencies = makeobj_dependencies(file)
        pak_mtime = File.exist?(pak_file) ? File.mtime(pak_file) : Time.at(0) # pakファイルが存在しない場合は1970年1月1日を基準とする
        next if dependencies.all? { |dep| File.exist?(dep) && File.mtime(dep) <= pak_mtime }
        queue << [file, size]
      end
    end

    # 並列処理
    threads = []
    Thread.ignore_deadlock = true
    THREAD_COUNT.times do
      threads << Thread.new do
        loop do
          file, size = queue.pop(true) rescue break
          output_path = 'Pak128.Japan-Ex+Addons/' + File.basename(file, '.dat') + '.pak'
          puts "create_pak: #{file} (size: #{size})"
          makeobj.create_pak(file, size, output_path)
        end
      end
    end

    threads.each(&:join)
  end

  # pakファイルの依存関係を取得する
  # 以下の場合、yyy.pngを依存関係として取得する
  # xxx[12][34]=yyy.12.34
  # xxx=> yyy.12.34
  def makeobj_dependencies(dat_file)
    dependencies = [dat_file]
    File.open(dat_file, 'r') do |file|
      file.each_line do |line|
        if line =~ /^\w+(\[\w+\])*=(> )?((\.\.\/)*\w+)\.\d+\.\d+/
          require_file = File.expand_path("#{$3}.png", File.dirname(dat_file))
          dependencies << require_file
        end
      end
    end
    dependencies.uniq
  end

  # jatabファイルとentabファイルを集めてja.tabとen.tabを作成する
  def maketab()
    FileUtils.mkdir_p('Pak128.Japan-Ex+Addons/text')
    puts 'maketab: ja.tab'
    jatab_files = Dir.glob('**/*.jatab') + ['text/ja.tab']
    open('Pak128.Japan-Ex+Addons/text/ja.tab', 'w') do |file|
      file.print '§'
      jatab_files.each do |jatab_file|
        File.open(jatab_file, 'r') do |jatab|
          jatab.each_line do |line|
            # jatabファイルの内容をそのままja.tabに書き込む
            file.puts line.chomp
          end
        end
      end
    end
    puts 'maketab: en.tab'
    entab_files = Dir.glob('**/*.entab') + ['text/en.tab']
    open('Pak128.Japan-Ex+Addons/text/en.tab', 'w') do |file|
      file.print '§'
      entab_files.each do |entab_file|
        File.open(entab_file, 'r') do |entab|
          entab.each_line do |line|
            # entabファイルの内容をそのままen.tabに書き込む
            file.puts line.chomp
          end
        end
      end
    end
  end

  # 必要なファイルをコピー
  def copy
    puts "copy config files"
    FileUtils.mkdir_p('Pak128.Japan-Ex+Addons/config')
    Dir.glob('config/*').each do |file|
      FileUtils.cp(file, 'Pak128.Japan-Ex+Addons/config/')
    end
    puts "copy README.md"
    FileUtils.cp('README.md', 'Pak128.Japan-Ex+Addons/README.md')
  end

  # 環境変数VERSIONを見て、Pak128.Japan-Ex+Addons/version.txtを作成する
  # もしVERSIONが設定されていなければ、"dev"を指定する
  def version
    puts "version: #{VERSION}"
    FileUtils.mkdir_p('Pak128.Japan-Ex+Addons')
    File.open('Pak128.Japan-Ex+Addons/version.txt', 'w') do |file|
      file.puts <<~EOS
        #{VERSION}

        バージョンの説明:
        v1.2.3 : リリースバージョン
        n123   : 開発中のバージョン(CDによるビルド)
        dev    : 開発中のバージョン(ローカルビルド)

        Version Description:
        v1.2.3 : Released version
        n123   : Development version (built via CD)
        dev    : Development version (local build)
      EOS
    end
  end

  def clean
    # datファイルは同名のdattファイルがある場合のみ削除する
    # .dattファイルが無い場合、警告メッセージを出力する
    Dir.glob('**/*.dat').each do |file|
      datt_file = file.sub(/\.dat$/, '.datt')
      if File.exist?(datt_file)
        puts "clean: #{file}"
        FileUtils.rm(file)
      else
        puts "Warning: No corresponding .datt file for #{file}, skipping deletion."
      end
    end
    puts "clean: pak files"
    FileUtils.rm_rf(Dir.glob('**/*.pak'))
    puts "clean: jatab files"
    FileUtils.rm_rf(Dir.glob('**/*.jatab'))
    puts "clean: entab files"
    FileUtils.rm_rf(Dir.glob('**/*.entab'))
    puts "clean: Pak128.Japan-Ex+Addons directory"
    FileUtils.rm_rf('Pak128.Japan-Ex+Addons')
  end
end

make = Make.new
make.run(ARGV)
