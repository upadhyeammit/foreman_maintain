class Features::Service < ForemanMaintain::Feature
  metadata do
    label :service
  end

  def handle_services(spinner, action, options = {})
    # options is used to handle "exclude" and "only" and "include" i.e.
    # { :only => ["httpd"] }
    # { :exclude => ["pulp-workers", "tomcat"] }
    # { :include => ["crond"] }
    if feature(:instance).downstream && feature(:instance).downstream.less_than_version?('6.3')
      use_katello_service(action, options)
    else
      use_system_service(action, options, spinner)
    end
  end

  def existing_services
    ForemanMaintain.available_features.map(&:services).
      flatten(1).
      sort.
      inject([]) do |pool, service| # uniq(&:to_s) for ruby 1.8.7
        pool.last.nil? || !pool.last.matches?(service) ? pool << service : pool
      end.
      select(&:exist?)
  end

  def filtered_services(options, action = '')
    services = include_unregistered_services(existing_services, options[:include])
    services = filter_services(action, options, services)
    raise 'No services found matching your parameters' unless services.any?
    return services unless options[:reverse]

    Hash[services.sort_by { |k, _| k.to_i }.reverse]
  end

  def action_noun(action)
    action_word_modified(action) + 'ing'
  end

  def action_past_tense(action)
    action_word_modified(action) + 'ed'
  end

  private

  def use_system_service(action, options, spinner)
    options[:reverse] = action == 'stop'
    raise 'Unsupported action detected' unless allowed_action?(action)

    status, failed_services = run_action_on_services(action, options, spinner)

    spinner.update("All services #{action_past_tense(action)}")
    if action == 'status'
      raise "Some services are not running (#{failed_services.join(', ')})" if status > 0

      spinner.update('All services are running')
    end
  end

  def run_action_on_services(action, options, spinner)
    status = 0
    failed_services = []
    filtered_services(options, action).each_value do |group|
      systemctl_status, _output = execute_with_status('systemctl ' \
        "#{action} #{group.map(&:name).join(' ')}")
      display_status(group, options, action, spinner)
      if systemctl_status > 0
        status = systemctl_status
        failed_services |= failed_services_by_status(action, group, spinner)
      end
    end
    [status, failed_services]
  end

  def display_status(services, options, action, spinner)
    services.each do |service|
      spinner.update("#{action_noun(action)} #{service}")
      formatted = format_status(service.status, options, action)
      puts formatted unless formatted.empty?
    end
  end

  def format_status(service_status, options, action)
    exit_code, output = service_status
    status = ''
    if !options[:failing] || exit_code > 0
      if options[:brief]
        status += format_brief_status(exit_code)
      elsif include_output?(action, exit_code)
        status += "\n" + output
      end
    end
    status
  end

  def include_output?(action, status)
    (action == 'start' && status > 0) ||
      action == 'status'
  end

  def format_brief_status(exit_code)
    result = exit_code == 0 ? reporter.status_label(:success) : reporter.status_label(:fail)
    padding = reporter.max_length - reporter.last_line.to_s.length - 30
    "#{' ' * padding} #{result}"
  end

  def failed_services_by_status(action, services, spinner)
    failed_services = []
    services.each do |service|
      spinner.update("#{action_noun(action)} #{service}")
      failed_services << service unless service.running?
    end
    failed_services
  end

  def allowed_action?(action)
    %w[start stop restart status enable disable].include?(action)
  end

  def extend_service_list_with_sockets(service_list, options)
    return service_list unless options[:include_sockets]

    socket_list = service_list.map(&:socket).compact.select(&:exist?)
    service_list + socket_list
  end

  # rubocop:disable Metrics/AbcSize
  def filter_services(action, options, service_list)
    if options[:only] && options[:only].any?
      service_list = service_list.select do |service|
        options[:only].any? { |opt| service.matches?(opt) }
      end
      service_list = include_unregistered_services(service_list, options[:only])
    end

    if options[:exclude] && options[:exclude].any?
      service_list = service_list.reject { |service| options[:exclude].include?(service.name) }
    end

    service_list = extend_service_list_with_sockets(service_list, options)
    service_list = filter_disabled_services!(service_list, action)
    service_list.group_by(&:priority).to_h
  end
  # rubocop:enable Metrics/AbcSize

  def filter_disabled_services!(service_list, action)
    if %w[start stop restart status].include?(action)
      service_list.select!(&:enabled?)
    end
    service_list
  end

  def include_unregistered_services(service_list, services_filter)
    return service_list unless services_filter
    return service_list unless services_filter.any?

    services_filter = services_filter.reject do |obj|
      service_list.any? { |service| service.matches?(obj) }
    end

    unregistered_service_list = services_filter.map do |obj|
      service = if obj.is_a? String
                  system_service(obj)
                elsif valid_sys_service?(obj)
                  obj
                end
      service.exist? ? service : raise("No service found matching your parameter '#{service.name}'")
    end

    service_list.concat(unregistered_service_list)
    service_list
  end

  def action_word_modified(action)
    case action
    when 'status'
      'display'
    when 'enable', 'disable'
      action.chomp('e')
    when 'stop'
      action + 'p'
    else
      action
    end
  end

  def use_katello_service(action, options)
    if %w[enable disable].include?(action)
      raise 'Service enable and disable are only supported in Satellite 6.3+'
    end

    command = "katello-service #{action} "

    # katello-service in 6.1 does not support --only
    if feature(:instance).downstream.less_than_version?('6.2')
      excluded_services = exclude_services_only(options)
      command += "--exclude #{excluded_services.join(',')}" if excluded_services.any?
    else
      command += katello_service_filters(options)
    end

    run_katello_service(command)
  end

  def run_katello_service(command)
    puts "Services are handled by katello-service in Satellite versions 6.2 and earlier. \n" \
         "Flags --brief or --failing will be ignored if present. \n"\
         "Similarly, services that are not listed by katello-service will get ignored. \n"\
         "Redirecting to: \n#{command}\n"
    puts execute(command)
  end

  def exclude_services_only(options)
    existing_services - filtered_services(options)
  end

  def katello_service_filters(options)
    filters = ''
    if options[:exclude] && options[:exclude].any?
      filters += "--exclude #{options[:exclude].join(',')}"
    end
    if options[:only] && options[:only].any?
      filters += "--only #{options[:only].join(',')}"
    end
    filters
  end
end
