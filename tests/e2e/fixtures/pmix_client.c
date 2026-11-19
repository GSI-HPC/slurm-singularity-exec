/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * PMIx client of the end-to-end tests. It connects to the PMIx server of
 * its step, as an MPI library does, and prints its rank and the number of
 * tasks of the step.
 */
#include <stdio.h>
#include <pmix.h>

int main(void)
{
	pmix_proc_t proc, wildcard;
	pmix_value_t *value = NULL;
	pmix_status_t rc;
	unsigned size = 0;

	if ((rc = PMIx_Init(&proc, NULL, 0)) != PMIX_SUCCESS) {
		fprintf(stderr, "PMIx_Init: %s\n", PMIx_Error_string(rc));
		return 1;
	}

	PMIX_PROC_LOAD(&wildcard, proc.nspace, PMIX_RANK_WILDCARD);
	if ((rc = PMIx_Get(&wildcard, PMIX_JOB_SIZE, NULL, 0, &value)) ==
	    PMIX_SUCCESS) {
		size = value->data.uint32;
		PMIX_VALUE_RELEASE(value);
	}

	printf("pmix rank=%u size=%u\n", proc.rank, size);
	return (PMIx_Finalize(NULL, 0) != PMIX_SUCCESS);
}
