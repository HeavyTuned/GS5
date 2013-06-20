-- Gemeinschaft 5 module: log
-- (c) AMOOMA GmbH 2012-2013
-- 

module(...,package.seeall)

Log = {}

-- Create logger object
function Log.new(self, arg)
  arg = arg or {}
  object = arg.object or {}
  setmetatable(object, self);
  self.__index = self;
  self.disabled = arg.disabled or false;
  self.buffer = arg.buffer;
  self.prefix = arg.prefix or '### ';

  self.level_console  = arg.level_console  or 0;
  self.level_alert    = arg.level_alert    or 1;
  self.level_critical = arg.level_critical or 2;
  self.level_error    = arg.level_error    or 3;
  self.level_warning  = arg.level_warning  or 4;
  self.level_notice   = arg.level_notice   or 5;
  self.level_info     = arg.level_info     or 6;
  self.level_debug    = arg.level_debug    or 7;
  self.level_devel    = arg.level_devel    or 4;

  return object;
end

function Log.message(self, log_level, message_arguments )
  if self.disabled then
    return
  end
  local message = tostring(self.prefix);
  for index, value in pairs(message_arguments) do
    if type(index) == 'number' then
      if type(value) == 'table' then
        require 'common.array';
        message = message .. common.array.to_json(value, 3);
      else
        message = message .. tostring(value);
      end
    end
  end
  if self.buffer then
    table.insert(self.buffer, message);
  elseif freeswitch then
    freeswitch.consoleLog(log_level, message .. '\n');
  end
end

function Log.console(self, ...)
  self:message(self.level_console, {...});
end

function Log.alert(self, ...)
  self:message(self.level_alert, {...});
end

function Log.critical(self, ...)
  self:message(self.level_critical, {...});
end

function Log.error(self, ...)
  self:message(self.level_error, {...});
end

function Log.warning(self, ...)
  self:message(self.level_warning, {...});
end

function Log.notice(self, ...)
  self:message(self.level_notice, {...});
end

function Log.info(self, ...)
  self:message(self.level_info, {...});
end

function Log.debug(self, ...)
  self:message(self.level_debug, {...});
end

function Log.devel(self, ...)
  local arguments = {...};
  table.insert(arguments, 1, '**');
  self:message(self.level_devel, arguments);
end
