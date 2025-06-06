public with sharing class LeaveOfAbsenceHandler {
    @AuraEnabled(cacheable=false)
    public static LeaveResult getEmployeeLeaveInfo(Id employeeId) {
        // Get employee leave records
        LeaveResult result = new LeaveResult();
        try {
            // Query Leave of Absence records
            List<Leave_of_Absense__c> leaveRecords = [
                SELECT Id, Name, Emp__c, Leave_Type__c, Status__c,
                       Start_Date__c, End_Date__c, Number_of_Days__c
                FROM Leave_of_Absense__c 
                WHERE Emp__c = :employeeId
                ORDER BY Start_Date__c DESC
                LIMIT 1
            ];
            
            if (!leaveRecords.isEmpty()) {
                Leave_of_Absense__c record = leaveRecords[0];
                result.id = record.Id;
                result.name = record.Name;
                result.empId = record.Emp__c;
                result.leaveType = record.Leave_Type__c;
                result.status = record.Status__c;
                result.startDate = record.Start_Date__c;
                result.endDate = record.End_Date__c;
                result.numberOfDays = record.Number_of_Days__c;
            }
            result.success = true;
            
        } catch(Exception e) {
            result.success = false;
            result.errorMessage = 'Error retrieving leave records: ' + e.getMessage();
            System.debug('ERROR in getEmployeeLeaveInfo: ' + e.getMessage());
        }
        System.debug('=== getEmployeeLeaveInfo FINISHED ===');
        return result;
    }

    @AuraEnabled(cacheable=false)
    public static List<LeaveTypeSummary> getEmployeeLeaveTypeSummary(Id employeeId) {
        // Get comprehensive leave summary with Einstein AI allocations
        
        List<LeaveTypeSummary> summaries = new List<LeaveTypeSummary>();
        
        try {
            // First, get the contact's salutation to determine appropriate leave types
            List<Contact> employees = [
                SELECT Id, Name, Salutation
                FROM Contact 
                WHERE Id = :employeeId
                LIMIT 1
            ];
            
            if (employees.isEmpty()) {
                System.debug('ERROR: No Contact found with ID: ' + employeeId);
                return summaries; // Return empty list
            }
            
            Contact employee = employees[0];
            System.debug('Found employee: ' + employee.Name + ', Salutation: ' + employee.Salutation);
            
            // Query and aggregate leave records by type
            AggregateResult[] groupedResults = [
                SELECT Leave_Type__c, COUNT(Id) recordCount, 
                       SUM(Number_of_Days__c) totalDays
                FROM Leave_of_Absense__c 
                WHERE Emp__c = :employeeId
                AND Status__c IN ('Approved', 'Pending')
                GROUP BY Leave_Type__c
            ];
            
            // Try to get allocated days from prompt template system
            System.debug('Calling getAllocatedDaysFromKnowledge...');
            Map<String, Decimal> allocatedDaysMap = getAllocatedDaysFromKnowledge(employeeId, employee.Salutation);
            System.debug('Allocated days map from Einstein: ' + allocatedDaysMap);
            
            // Get all unique leave types (from both records and prompt template)
            Set<String> allLeaveTypes = new Set<String>();
            
            // Add leave types from actual records
            for (AggregateResult ar : groupedResults) {
                allLeaveTypes.add((String)ar.get('Leave_Type__c'));
            }
            
            // Add leave types from prompt template (if available)
            allLeaveTypes.addAll(allocatedDaysMap.keySet());
            
            // Filter to only show applicable leave types based on salutation (completely hide non-applicable ones)
            Set<String> applicableLeaveTypes = getApplicableLeaveTypes(employee.Salutation);
            
            // Keep only the intersection of allocated types and applicable types
            Set<String> filteredLeaveTypes = new Set<String>();
            for (String leaveType : applicableLeaveTypes) {
                filteredLeaveTypes.add(leaveType);
            }
            allLeaveTypes = filteredLeaveTypes;
            
            System.debug('All leave types to display: ' + allLeaveTypes);
            
            // Create summaries for applicable leave types only
            for (String leaveType : allLeaveTypes) {
                LeaveTypeSummary summary = new LeaveTypeSummary();
                summary.leaveType = leaveType;
                
                // Get allocated days from prompt template results (all types in allLeaveTypes are applicable)
                summary.allocatedDays = allocatedDaysMap.containsKey(leaveType) ? 
                    allocatedDaysMap.get(leaveType) : 0;
                

                
                // Find matching aggregate result for this leave type
                Decimal usedDays = 0;
                Integer recordCount = 0;
                
                for (AggregateResult ar : groupedResults) {
                    if (leaveType.equals((String)ar.get('Leave_Type__c'))) {
                        usedDays = (Decimal)ar.get('totalDays');
                        recordCount = (Integer)ar.get('recordCount');
                        break;
                    }
                }
                
                // Ensure used days is always positive (take absolute value to handle data quality issues)
                summary.usedDays = usedDays != null ? Math.abs(usedDays) : 0;
                summary.recordCount = recordCount != null ? recordCount : 0;
                summary.remainingDays = summary.allocatedDays - summary.usedDays;
                
                summaries.add(summary);
            }
            
            // Sort summaries by allocated days in descending order (highest allocation first)
            summaries.sort(new LeaveTypeSummaryComparator());
            
            // Successfully processed summaries
            
        } catch(Exception e) {
            // Log error but return empty list to prevent UI breaks
            System.debug('Error getting leave summary: ' + e.getMessage());
            return new List<LeaveTypeSummary>();
        }
        
        return summaries;
    }
    
    // Helper method to get allocated days from knowledge articles via prompt template
    // Returns empty map if prompt template is inactive (will result in 0s being shown)
    private static Map<String, Decimal> getAllocatedDaysFromKnowledge(Id employeeId, String salutation) {
        Map<String, Decimal> allocatedDays = new Map<String, Decimal>();
        
        try {
            // Get all available leave types from configuration - NO hard-coded lists
            Set<String> promptLeaveTypes = getAllConfiguredLeaveTypes();
            
            if (String.isNotBlank(salutation)) {
                // Add only the applicable family leave type for the prompt
                salutation = salutation.toLowerCase().trim();
                // Salutation-based filtering is now handled by getAllConfiguredLeaveTypes method
            }
            
            String leaveTypesText = String.join(new List<String>(promptLeaveTypes), ', ');
            
            // Get employee details to build a comprehensive question
            List<Contact> employees = [
                SELECT Id, Name, CreatedDate
                FROM Contact 
                WHERE Id = :employeeId
                LIMIT 1
            ];
            
            if (employees.isEmpty()) {
                System.debug('ERROR: No Contact found for Einstein call with ID: ' + employeeId);
                return allocatedDays; // Return empty map
            }
            
            Contact employee = employees[0];
            System.debug('Einstein call for employee: ' + employee.Name);
            
            // Calculate service duration using CreatedDate as hire date
            Date startDate = employee.CreatedDate.date();
            Date currentDate = Date.today();
            String serviceDuration = calculateServiceDuration(startDate, currentDate);
            
            // Get template ID from configuration - NO fallbacks
            String templateId = getPromptTemplateIdFromConfig();
            if (String.isBlank(templateId)) {
                System.debug('No prompt template ID configured - returning empty allocations');
                return allocatedDays; // Return empty map instead of throwing error
            }
            
            // Call Einstein AI sequentially for each leave type (better retrieval accuracy)
            System.debug('=== CALLING EINSTEIN AI FOR ALLOCATIONS (SEQUENTIAL) ===');
            System.debug('Employee: ' + employee.Name);
            System.debug('Service Duration: ' + serviceDuration);
            
            // Make individual calls for each leave type to improve retrieval accuracy
            for (String leaveType : promptLeaveTypes) {
                try {
                    String inputQuestion = String.format(
                        'My name is {0}. My hire date is {1}. I have been working for {2}. What are my allocated {3} days based on my service duration? Please provide specific numbers.',
                        new String[]{employee.Name, startDate.format(), serviceDuration, leaveType}
                    );
                    
                    System.debug('Calling Einstein for: ' + leaveType);
                    System.debug('Question: ' + inputQuestion);
                    
                    // Call Einstein API for this specific leave type
                    String aiResponse = callEinsteinDirectly(templateId, inputQuestion);
                    System.debug('Einstein response for ' + leaveType + ': ' + aiResponse);
                    
                    // Parse the response for this leave type
                    Map<String, Decimal> singleTypeResult = parseAllocatedDaysFromResponse(aiResponse);
                    
                    // Add to the main results map
                    if (!singleTypeResult.isEmpty()) {
                        allocatedDays.putAll(singleTypeResult);
                        System.debug('Added to results: ' + singleTypeResult);
                    } else {
                        System.debug('No allocation found for: ' + leaveType);
                    }
                    
                } catch (Exception e) {
                    System.debug('Error getting allocation for ' + leaveType + ': ' + e.getMessage());
                    // Continue with other leave types even if one fails
                }
            }
            
            System.debug('Final combined allocated days: ' + allocatedDays);
            
        } catch (Exception e) {
            System.debug('Error in getAllocatedDaysFromKnowledge: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            System.debug('Employee ID: ' + employeeId);
            System.debug('Salutation: ' + salutation);
            System.debug('Returning empty map - allocated days will show as 0');
        }
        
        return allocatedDays; // Empty map means 0 allocated days will be shown
    }
    
    // Get prompt template ID from configuration - NO fallbacks
    private static String getPromptTemplateIdFromConfig() {
        List<Leave_Allocation__mdt> configs = [
            SELECT Template_ID__c
            FROM Leave_Allocation__mdt
            WHERE Leave_Type__c = 'PROMPT_TEMPLATE_CONFIG'
            AND Template_ID__c != null
            LIMIT 1
        ];
        
        return configs.isEmpty() ? null : configs[0].Template_ID__c;
    }
    
    // Get all configured leave types - NO hard-coded lists
    private static Set<String> getAllConfiguredLeaveTypes() {
        List<Leave_Allocation__mdt> configs = [
            SELECT Leave_Type__c
            FROM Leave_Allocation__mdt
            WHERE Leave_Type__c NOT IN ('PROMPT_TEMPLATE_CONFIG', 'NAMED_CREDENTIAL_CONFIG')
        ];
        
        Set<String> leaveTypes = new Set<String>();
        for (Leave_Allocation__mdt config : configs) {
            leaveTypes.add(config.Leave_Type__c);
        }
        
        if (leaveTypes.isEmpty()) {
            throw new CalloutException('No leave types configured in Leave_Allocation__mdt metadata');
        }
        
                return leaveTypes;
    }

    // Call Einstein API directly without going through InvocableMethod
    private static String callEinsteinDirectly(String templateId, String inputQuestion) {
        try {
            // Use the actual working Einstein API
            ConnectApi.EinsteinPromptTemplateGenerationsInput promptGenerationsInput = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            promptGenerationsInput.isPreview = false;
            
            Map<String,ConnectApi.WrappedValue> valueMap = new Map<String,ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue strWrappedValue = new ConnectApi.WrappedValue();
            strWrappedValue.value = inputQuestion;
                                            
            valueMap.put('Input:input', strWrappedValue); 
                                            
            promptGenerationsInput.inputParams = valueMap;
                                            
            // Set additional configuration values
            promptGenerationsInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            promptGenerationsInput.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';
                                            
            // Call the service using the prompt template ID
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation generationsOutput = 
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateId, promptGenerationsInput);
            
            // Extract the response from Einstein
            if (generationsOutput != null && generationsOutput.generations != null && !generationsOutput.generations.isEmpty()) {
                return generationsOutput.generations[0].text;
            } else {
                throw new CalloutException('No response from Einstein Prompt Template API');
            }
            
        } catch (Exception e) {
            System.debug('Einstein API error: ' + e.getMessage());
            throw new CalloutException('Einstein API failed: ' + e.getMessage());
        }
    }

    // Parse AI response to extract allocated days for different leave types
    private static Map<String, Decimal> parseAllocatedDaysFromResponse(String aiResponse) {
        Map<String, Decimal> allocatedDays = new Map<String, Decimal>();
        
        try {
            System.debug('=== PARSING AI RESPONSE ===');
            System.debug('Response to parse: ' + aiResponse);
            
            if (String.isBlank(aiResponse)) {
                return allocatedDays;
            }
            
            // Convert to lowercase for easier matching
            String response = aiResponse.toLowerCase();
            
            // First, try to find final summary section (most reliable)
            // Look for patterns like "- **Vacation**: 11.44 days" in summary sections
            Pattern finalSummaryPattern = Pattern.compile('-\\s*\\*\\*([^:]+?)\\*\\*:\\s*(\\d+(?:\\.\\d+)?)\\s*(days?|hours?)');
            Matcher summaryMatcher = finalSummaryPattern.matcher(response);
            
            Boolean foundSummary = false;
            while (summaryMatcher.find()) {
                try {
                    String leaveTypeMention = summaryMatcher.group(1).trim();
                    Decimal amount = Decimal.valueOf(summaryMatcher.group(2));
                    String unit = summaryMatcher.group(3).toLowerCase();
                    
                    // Convert hours to days (assuming 8 hours = 1 day)
                    if (unit.startsWith('hour')) {
                        amount = amount / 8;
                        System.debug('Converted hours to days in summary: ' + amount);
                    }
                    
                    // Map to standard leave type names
                    String standardType = mapToStandardLeaveType(leaveTypeMention);
                    if (String.isNotBlank(standardType) && isValidLeaveType(standardType)) {
                        allocatedDays.put(standardType, amount);
                        System.debug('Found summary: ' + standardType + ' = ' + amount + ' days');
                        foundSummary = true;
                    }
                    
                } catch (Exception e) {
                    System.debug('Error parsing summary pattern: ' + e.getMessage());
                }
            }
            
            // If we found a summary section, use only that and ignore other patterns
            if (foundSummary) {
                System.debug('Found summary section, using only summary values: ' + allocatedDays);
                return allocatedDays;
            }
            
            // Fallback: Look for "Total LeaveType: X days" patterns (second most reliable)
            Pattern totalPattern = Pattern.compile('total\\s+([^:]+?)\\s*:?[^\\d]*(\\d+(?:\\.\\d+)?)\\s*(days?|hours?)');
            Matcher totalMatcher = totalPattern.matcher(response);
            
            Boolean foundTotals = false;
            while (totalMatcher.find()) {
                try {
                    String leaveTypeMention = totalMatcher.group(1).trim();
                    Decimal amount = Decimal.valueOf(totalMatcher.group(2));
                    String unit = totalMatcher.group(3).toLowerCase();
                    
                    // Convert hours to days (assuming 8 hours = 1 day)
                    if (unit.startsWith('hour')) {
                        amount = amount / 8;
                        System.debug('Converted hours to days in total: ' + amount);
                    }
                    
                    String standardType = mapToStandardLeaveType(leaveTypeMention);
                    if (String.isNotBlank(standardType) && isValidLeaveType(standardType)) {
                        allocatedDays.put(standardType, amount);
                        System.debug('Found total: ' + standardType + ' = ' + amount + ' days');
                        foundTotals = true;
                    }
                    
                } catch (Exception e) {
                    System.debug('Error parsing total pattern: ' + e.getMessage());
                }
            }
            
            if (foundTotals) {
                System.debug('Found total values, using only totals: ' + allocatedDays);
                return allocatedDays;
            }
            
            // Last resort: Look for any clear leave type patterns but filter out calculations
            // Updated pattern to handle both days and hours
            Pattern basicPattern = Pattern.compile('([^:=()]+?)\\s*:?\\s*(\\d+(?:\\.\\d+)?)\\s*(days?|hours?)');
            Matcher basicMatcher = basicPattern.matcher(response);
            
            while (basicMatcher.find()) {
                try {
                    String leaveTypeMention = basicMatcher.group(1).trim();
                    String amountStr = basicMatcher.group(2);
                    String unit = basicMatcher.group(3).toLowerCase();
                    
                    // Skip if it looks like a calculation or intermediate result
                    if (leaveTypeMention.contains('(') || leaveTypeMention.contains('*') || 
                        leaveTypeMention.contains('=') || leaveTypeMention.contains('pro-rated') ||
                        leaveTypeMention.contains('partial') || leaveTypeMention.contains('full years') ||
                        leaveTypeMention.contains('annual allocation') || leaveTypeMention.contains('rounded')) {
                        continue;
                    }
                    
                    Decimal amount = Decimal.valueOf(amountStr);
                    
                    // Convert hours to days (assuming 8 hours = 1 day)
                    if (unit.startsWith('hour')) {
                        amount = amount / 8;
                        System.debug('Converted ' + amountStr + ' hours to ' + amount + ' days');
                    }
                    
                    String standardType = mapToStandardLeaveType(leaveTypeMention);
                    
                    if (String.isNotBlank(standardType) && isValidLeaveType(standardType)) {
                        allocatedDays.put(standardType, amount);
                        System.debug('Found basic pattern: ' + standardType + ' = ' + amount + ' days');
                    }
                    
                } catch (Exception e) {
                    System.debug('Error parsing basic pattern: ' + e.getMessage());
                }
            }
            
            System.debug('Final parsed allocated days: ' + allocatedDays);
            
        } catch (Exception e) {
            System.debug('Error parsing AI response: ' + e.getMessage());
        }
        
        return allocatedDays;
    }
    
    // Validate that this is a configured leave type we want to display
    private static Boolean isValidLeaveType(String leaveType) {
        Set<String> validTypes = getAllConfiguredLeaveTypes();
        return validTypes.contains(leaveType);
    }
    

    
    // Get applicable leave types for display (determines which rows to show)
    private static Set<String> getApplicableLeaveTypes(String salutation) {
        Set<String> allTypes = getAllConfiguredLeaveTypes();
        Set<String> applicableTypes = new Set<String>();
        
        for (String leaveType : allTypes) {
            // Filter based on salutation to show gender-appropriate leave types
            if (leaveType == 'Maternity Leave') {
                // Only show Maternity Leave for female salutations or when salutation is unknown
                if (String.isBlank(salutation) || salutation.equalsIgnoreCase('Mrs.') || salutation.equalsIgnoreCase('Ms.')) {
                    applicableTypes.add(leaveType);
                }
            } else if (leaveType == 'Paternity Leave') {
                // Only show Paternity Leave for male salutations or when salutation is unknown
                if (String.isBlank(salutation) || salutation.equalsIgnoreCase('Mr.')) {
                    applicableTypes.add(leaveType);
                }
            } else {
                // All other leave types apply to everyone
                applicableTypes.add(leaveType);
            }
        }
        
        System.debug('Applicable leave types for salutation "' + salutation + '": ' + applicableTypes);
        return applicableTypes;
    }

    // Calculate service duration between two dates
    private static String calculateServiceDuration(Date startDate, Date endDate) {
        if (startDate == null || endDate == null) {
            return '0 days';
        }
        
        // Calculate the difference
        Integer totalDays = startDate.daysBetween(endDate);
        
        if (totalDays < 0) {
            return '0 days';
        }
        
        // Calculate years, months, and remaining days
        Integer years = 0;
        Integer months = 0;
        Integer days = 0;
        
        Date currentDate = startDate;
        
        // Calculate full years
        while (currentDate.addYears(1) <= endDate) {
            years++;
            currentDate = currentDate.addYears(1);
        }
        
        // Calculate full months
        while (currentDate.addMonths(1) <= endDate) {
            months++;
            currentDate = currentDate.addMonths(1);
        }
        
        // Calculate remaining days
        days = currentDate.daysBetween(endDate);
        
        // Format the result
        List<String> parts = new List<String>();
        if (years > 0) {
            parts.add(years + ' year' + (years > 1 ? 's' : ''));
        }
        if (months > 0) {
            parts.add(months + ' month' + (months > 1 ? 's' : ''));
        }
        if (days > 0) {
            parts.add(days + ' day' + (days > 1 ? 's' : ''));
        }
        
        return parts.isEmpty() ? '0 days' : String.join(parts, ', ');
    }
    
    // Map various leave type mentions to standard picklist values
    private static String mapToStandardLeaveType(String leaveType) {
        if (String.isBlank(leaveType)) {
            return null;
        }
        
        leaveType = leaveType.toLowerCase().trim();
        
        // Remove common prefixes/suffixes
        leaveType = leaveType.replaceAll('\\*\\*', ''); // Remove markdown bold
        leaveType = leaveType.replaceAll('^-\\s*', ''); // Remove leading dash
        leaveType = leaveType.replaceAll('\\s*leave\\s*$', ''); // Remove trailing "leave"
        leaveType = leaveType.trim();
        
        if (leaveType.contains('vacation')) {
            return 'Vacation';
        } else if (leaveType.contains('pto') || leaveType.contains('paid time off')) {
            return 'PTO';
        } else if (leaveType.contains('sick')) {
            return 'Sick Leave';
        } else if (leaveType.contains('personal')) {
            return 'PTO';
        } else if (leaveType.contains('maternity')) {
            return 'Maternity Leave';
        } else if (leaveType.contains('paternity')) {
            return 'Paternity Leave';
        } else if (leaveType.contains('holiday')) {
            return 'Holidays';
        } else if (leaveType.contains('bereavement')) {
            return 'Bereavement Leave';
        } else {
            // Return the original for unmapped types
            return leaveType.substring(0, 1).toUpperCase() + leaveType.substring(1);
        }
    }
    
    // Output wrapper class for single record
    public class LeaveResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id empId;
        @AuraEnabled public String leaveType;
        @AuraEnabled public String status;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public Decimal numberOfDays;
    }

    // Output wrapper class for leave type summary
    public class LeaveTypeSummary {
        @AuraEnabled public String leaveType;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public Decimal allocatedDays;
        @AuraEnabled public Decimal usedDays;
        @AuraEnabled public Decimal remainingDays;
    }
    
    // Comparator to sort leave type summaries by allocated days (highest first)
    public class LeaveTypeSummaryComparator implements Comparator<LeaveTypeSummary> {
        public Integer compare(LeaveTypeSummary a, LeaveTypeSummary b) {
            // Sort by allocated days descending (highest first)
            if (a.allocatedDays > b.allocatedDays) return -1;
            if (a.allocatedDays < b.allocatedDays) return 1;
            
            // If allocatedDays are equal, sort alphabetically by leave type name
            return a.leaveType.compareTo(b.leaveType);
        }
    }
} 