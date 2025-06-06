import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import getEmployeeLeaveInfo from '@salesforce/apex/LeaveOfAbsenceHandler.getEmployeeLeaveInfo';
import getEmployeeLeaveTypeSummary from '@salesforce/apex/LeaveOfAbsenceHandler.getEmployeeLeaveTypeSummary';

// Field imports
import EMP_FIELD from '@salesforce/schema/Leave_of_Absense__c.Emp__c';
import LEAVE_TYPE_FIELD from '@salesforce/schema/Leave_of_Absense__c.Leave_Type__c';
import START_DATE_FIELD from '@salesforce/schema/Leave_of_Absense__c.Start_Date__c';
import END_DATE_FIELD from '@salesforce/schema/Leave_of_Absense__c.End_Date__c';
import STATUS_FIELD from '@salesforce/schema/Leave_of_Absense__c.Status__c';

export default class EmployeePtoInfo extends NavigationMixin(LightningElement) {
    _recordId; // This will store the Contact record Id
    leaveRecords;
    leaveSummaries;
    error;
    isLoading = true;
    isModalOpen = false;

    fields = [EMP_FIELD, LEAVE_TYPE_FIELD, START_DATE_FIELD, END_DATE_FIELD, STATUS_FIELD];

    constructor() {
        super();
    }

    connectedCallback() {
        // Component connected - ready to load data when recordId is set
    }

    // Load leave records imperatively
    async loadLeaveRecords() {
        if (!this.recordId) return;
        
        try {
            const data = await getEmployeeLeaveInfo({ employeeId: this.recordId });
            this.leaveRecords = data;
            this.error = undefined;
        } catch (error) {
            this.error = error;
            this.leaveRecords = undefined;
        }
        this.checkLoading();
    }

    // Load leave summaries imperatively since Einstein API can't be cached
    async loadLeaveSummaries() {
        if (!this.recordId) {
            return;
        }
        
        try {
            const data = await getEmployeeLeaveTypeSummary({ employeeId: this.recordId });
            
            // Process the summaries to add UI-specific properties (now in hours)
            this.leaveSummaries = data.map(summary => ({
                ...summary,
                allocatedHoursDisplay: (Math.round((summary.allocatedDays || 0) * 8 * 100) / 100).toString(),
                usedHoursDisplay: (Math.round((summary.usedDays || 0) * 8 * 100) / 100).toString(),
                remainingHoursDisplay: (Math.round((summary.remainingDays || 0) * 8 * 100) / 100).toString(),
                usagePercentage: summary.allocatedDays > 0 ? Math.round((summary.usedDays / summary.allocatedDays) * 100) : 0,
                progressStyle: summary.allocatedDays > 0 ? `width: ${Math.min(Math.round((summary.usedDays / summary.allocatedDays) * 100), 100)}%` : 'width: 0%',
                remainingPercentage: summary.allocatedDays > 0 ? Math.round((summary.remainingDays / summary.allocatedDays) * 100) : 0
            }));
            
            this.error = undefined;
        } catch (error) {
            this.error = error;
            this.leaveSummaries = undefined;
        }
        this.checkLoading();
    }

    checkLoading() {
        // Set isLoading to false when operations complete
        this.isLoading = false;
    }

    // Load data when recordId changes
    @api 
    get recordId() {
        return this._recordId;
    }
    
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.loadLeaveRecords();
            this.loadLeaveSummaries();
        }
    }

    get hasLeaveRecords() {
        return this.leaveRecords && this.leaveRecords.success;
    }

    get hasLeaveSummaries() {
        return this.leaveSummaries && this.leaveSummaries.length > 0;
    }

    get showNoRecords() {
        return !this.isLoading && !this.error && !this.hasLeaveSummaries;
    }

    get totalAllocatedHours() {
        if (!this.hasLeaveSummaries) return '0';
        const totalDays = this.leaveSummaries.reduce((total, summary) => total + (summary.allocatedDays || 0), 0);
        return (Math.round(totalDays * 8 * 100) / 100).toString();
    }

    get totalHoursOff() {
        if (!this.hasLeaveSummaries) return '0';
        const totalDays = this.leaveSummaries.reduce((total, summary) => total + (summary.usedDays || 0), 0);
        return (Math.round(totalDays * 8 * 100) / 100).toString();
    }

    get totalRequests() {
        if (!this.hasLeaveSummaries) return '0';
        return this.leaveSummaries.reduce((total, summary) => total + (summary.recordCount || 0), 0).toString();
    }

    get totalRemainingHours() {
        if (!this.hasLeaveSummaries) return '0';
        const totalDays = this.leaveSummaries.reduce((total, summary) => total + (summary.remainingDays || 0), 0);
        return (Math.round(totalDays * 8 * 100) / 100).toString();
    }

    get totalBalanceClass() {
        const balanceInDays = this.hasLeaveSummaries ? 
            this.leaveSummaries.reduce((total, summary) => total + (summary.remainingDays || 0), 0) : 0;
        
        return balanceInDays < 0 ? 
            'slds-text-heading_medium slds-text-color_error' : 
            'slds-text-heading_medium';
    }

    get averageHoursPerRequest() {
        if (!this.hasLeaveSummaries || this.totalRequests === 0) return '0.0';
        const totalHours = parseFloat(this.totalHoursOff);
        const totalReqs = parseFloat(this.totalRequests);
        return (totalHours / totalReqs).toFixed(1);
    }

    get errorMessage() {
        if (!this.error) return '';
        
        // Handle different error structures
        let message = 'Unknown error occurred';
        
        if (this.error.body && this.error.body.message) {
            message = this.error.body.message;
        } else if (this.error.message) {
            message = this.error.message;
        } else if (typeof this.error === 'string') {
            message = this.error;
        }
        
        return 'Error loading PTO information: ' + message;
    }

    get defaultValues() {
        const defaults = {};
        if (this.recordId) {
            defaults['Emp__c'] = this.recordId;
            // Convert to string format that the form expects
            return Object.entries(defaults)
                .map(([key, value]) => `${key}=${value}`)
                .join(',');
        }
        return '';
    }

    handleNewLeaveRequest() {
        const defaultValues = encodeDefaultFieldValues({
            Emp__c: this.recordId
        });

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Leave_of_Absense__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: defaultValues
            }
        });
    }

    handleShowModal() {
        this.isModalOpen = true;
    }

    handleCloseModal() {
        this.isModalOpen = false;
    }

    async handleSuccess(event) {
        this.isModalOpen = false;
        
        // Show success toast
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Success',
                message: 'Leave request created successfully',
                variant: 'success'
            })
        );

        // Reload both data sets
        await this.loadLeaveRecords();
        await this.loadLeaveSummaries();
    }


} 